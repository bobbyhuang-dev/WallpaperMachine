/// End-to-end proof for the native Metal scene backend.
///
/// Parses an author project the ordinary way, with the native renderer
/// selected, then:
///   1. feeds the translated Metal Shading Language to `newLibraryWithSource:`
///      -- the first time anything has done so -- and reports the compiler's
///      own diagnostic verbatim if it refuses,
///   2. builds the real render graph and draws it with
///      `MTLRenderCommandEncoder`, and
///   3. reads the scene's own output image back and checks the author's shader
///      actually wrote it.
///
/// Creates only private GPU textures and an offscreen layer. No window, no
/// desktop, no audio device, no screen capture.

#include "Runtime/RuntimeImageSource.hpp"
#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalRender.hpp"
#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"

#include "Audio/AudioResponseService.h"
#include "Audio/SoundManager.h"
#include "Core/Random.hpp"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Particle/ParticleSystem.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneBackendSelection.hpp"
#include "Scene/SceneUpdateDemand.hpp"
#include "Scene/SceneNode.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneTexture.h"
#include "SpriteAnimation.hpp"
#include "SpecTexs.hpp"
#include "WPShaderValueUpdater.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "Shader/SceneMetalVariants.hpp"
#include "Scene/Parse/WPShaderParser.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "WPSceneParser.hpp"
#include "WPPkgFs.hpp"
#include "SceneSourceResolver.hpp"
#include "synthetic_video.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <array>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <span>
#include <string>
#include <thread>

using namespace wallpaper;
using namespace wallpaper::metal;

namespace
{

/// A minimal original scene: one flat-coloured card drawn through the author's
/// own vertex and fragment shaders. Small on purpose -- the point is that the
/// shader is real and travels the whole pipeline, not that the scene is rich.
/// `blue` picks the constant the fragment shader writes, which is only ever
/// varied to make a fixture's translated program textually unique -- the one
/// test that has to observe a cold compile needs a source no earlier test in
/// the same process has already compiled.
std::filesystem::path WriteFixture(const std::filesystem::path& root,
                                   std::string_view blue = "0.25")
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    const std::string fragment =
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_FragColor = vec4(v_TexCoord.x, v_TexCoord.y, " + std::string(blue) + ", 1.0);\n"
        "}\n";

    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal draw smoke","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        { "models/tile.json", R"({"width":256,"height":192,"material":"materials/tile.json"})" },
        { "materials/tile.json",
          R"({"passes":[{"shader":"metal_probe","blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]})" },
        { "shaders/metal_probe.vert", vertex },
        { "shaders/metal_probe.frag", fragment },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return root / "project.json";
}

struct LoadedScene
{
    fs::VFS                vfs;
    audio::SoundManager    sound; // Never Init/Play.
    ProjectProperties      properties;
    std::shared_ptr<Scene> scene;
};

bool LoadScene(const std::filesystem::path& project, const std::filesystem::path& cache,
               LoadedScene& out, std::string& error)
{
    const auto directory = project.parent_path();
    if (! out.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "assets")) {
        error = "assets mount failed";
        return false;
    }
    if (! out.vfs.Mount("/cache", fs::CreatePhysicalFs(cache.string(), true), "cache")) {
        error = "cache mount failed";
        return false;
    }
    InstallVirtualAssets(out.vfs);
    if (! ParseProjectProperties(project.string(), &out.properties, &error)) return false;

    auto source = out.vfs.Open("/assets/layout.json");
    if (source == nullptr) {
        error = "scene source missing";
        return false;
    }
    WPSceneParser parser;
    out.scene = parser.Parse(SceneParseRequest {
                                 .scene_id           = "metal-draw-smoke",
                                 .project_path       = project.string(),
                                 .project_properties = &out.properties,
                             },
                             source->ReadAllStr(), out.vfs, out.sound);
    if (out.scene == nullptr) {
        error = "scene parse failed";
        return false;
    }
    return true;
}

SceneNode* FirstDrawableNode(SceneNode* node)
{
    if (node == nullptr) return nullptr;
    if (auto* mesh = node->Mesh(); mesh != nullptr && mesh->MaterialForSlot(0) != nullptr) {
        return node;
    }
    for (const auto& child : node->GetChildren()) {
        if (auto* found = FirstDrawableNode(child.get()); found != nullptr) return found;
    }
    return nullptr;
}

rg::TexNode::Desc TexDesc(const std::string& key)
{
    return rg::TexNode::Desc {
        .name = key,
        .key  = key,
        .type = IsSpecTex(key) ? rg::TexNode::TexType::Temp : rg::TexNode::TexType::Imported,
    };
}

void AddDraw(rg::RenderGraph& graph, SceneNode* node, const std::string& output,
             const std::vector<std::string>& inputs)
{
    graph.addPass<vulkan::CustomShaderPass>(
        "draw", rg::PassNode::Type::CustomShader,
        [node, &output, &inputs](rg::RenderGraphBuilder&          builder,
                                 vulkan::CustomShaderPass::Desc& desc) {
            desc.node             = node;
            desc.visibility_node  = node;
            desc.output           = output;
            desc.write_alpha      = output != SpecTex_Default;
            desc.clear_on_first_use = true;
            for (const auto& input : inputs) {
                auto* tex = builder.createTexNode(TexDesc(input));
                if (IsSpecTex(input)) builder.markVirtualWrite(tex);
                builder.read(tex);
                desc.textures.push_back(std::string(tex->key()));
            }
            builder.write(builder.createTexNode(TexDesc(output), true));
        });
}

void AddCopy(rg::RenderGraph& graph, const std::string& source, const std::string& destination)
{
    graph.addPass<vulkan::CopyPass>(
        "copy", rg::PassNode::Type::Copy,
        [&source, &destination](rg::RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc) {
            auto* in  = builder.createTexNode(TexDesc(source));
            auto* out = builder.createTexNode(TexDesc(destination), true);
            builder.read(in);
            builder.write(out);
            desc.src = std::string(in->key());
            desc.dst = std::string(out->key());
        });
}

/// Asks for this scene's optional programs and waits, bounded, for the
/// background translation to settle.
///
/// The wallpaper's own loop asks for exactly this at a frame boundary and never
/// waits; a test that wants to compare the two paths has to know the second one
/// exists before it starts drawing, which is what this waits for.
bool SettleVariantTranslation(Scene& scene, std::string* reason,
                              std::string_view cache_root = {})
{
    RequestSceneMetalVariants(scene, true, cache_root);
    for (const auto& program : scene.metal_variant_candidates) {
        if (program == nullptr) continue;
        for (int attempt = 0; attempt < 500; ++attempt) {
            if (program->videoPlaneState() != SceneMetalVariantState::Pending) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        const auto state = program->videoPlaneState();
        if (state == SceneMetalVariantState::Ready) continue;
        if (reason != nullptr) {
            const auto variant = program->videoPlanes();
            *reason = state == SceneMetalVariantState::Failed && variant != nullptr
                          ? variant->error
                          : "the optional translation did not finish";
        }
        return false;
    }
    return true;
}

/// Draws, without advancing the scene clock, until the frame path settles on
/// the one asked for.
///
/// Bounded and not immediate on purpose: the optional pipeline is built off the
/// frame thread, so the frame that adopts it is the first one after the build
/// came back rather than the first one after the setting changed. That is the
/// behaviour, not a tolerance.
bool DrawUntilVideoPath(MetalRender& render, Scene& scene, SceneVideoPath wanted,
                        int frames = 64)
{
    for (int frame = 0; frame < frames; ++frame) {
        if (! render.drawFrame(scene)) return false;
        if (render.VideoPath() == wanted) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return false;
}

SceneMaterial* FirstMaterial(SceneNode* node)
{
    if (node == nullptr) return nullptr;
    if (auto* mesh = node->Mesh(); mesh != nullptr && mesh->MaterialForSlot(0) != nullptr) {
        return mesh->MaterialForSlot(0);
    }
    for (const auto& child : node->GetChildren()) {
        if (auto* found = FirstMaterial(child.get()); found != nullptr) return found;
    }
    return nullptr;
}

class MetalSceneDraw : public ::testing::Test {
protected:
    void SetUp() override
    {
        if (! MetalDeviceAvailable()) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        root_ = std::filesystem::temp_directory_path() /
                ("owe-metal-smoke-" + std::to_string(::getpid()));
        std::filesystem::remove_all(root_);
        std::filesystem::create_directories(root_);
        SetSceneRendererPreference(SceneRendererPreference::NativeMetalPreferred);
        ForgetMetalPrepareFailures();
    }

    void TearDown() override
    {
        SetSceneRendererPreference(SceneRendererPreference::Compatibility);
        ForgetMetalPrepareFailures();
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }

    std::filesystem::path root_;
};

} // namespace

TEST_F(MetalSceneDraw, TranslatedAuthorShaderCompilesAndDrawsTheScene)
{
    const auto project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    // ---- 1. the parser produced a translation at all
    auto* material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr) << "the parser hook did not run with the native preference on";
    ASSERT_TRUE(program->error.empty()) << "metal translation failed: " << program->error;
    ASSERT_FALSE(program->stages.empty());

    // ---- 2. the Metal compiler accepts it
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        ASSERT_NE(device, nil);
        for (const auto& stage : program->stages) {
            EXPECT_EQ(stage.entry_point, "main_")
                << "the backend reads the entry point from the stage, so this is a contract check";
            NSError*  compile_error = nil;
            NSString* source = [NSString stringWithUTF8String:stage.source.c_str()];
            id<MTLLibrary> library = [device newLibraryWithSource:source
                                                          options:[MTLCompileOptions new]
                                                            error:&compile_error];
            ASSERT_NE(library, nil)
                << "Metal refused the translated shader: "
                << (compile_error != nil ? compile_error.localizedDescription.UTF8String
                                         : "unknown error")
                << "\n----- generated MSL -----\n"
                << stage.source;
            NSString* entry = [NSString stringWithUTF8String:stage.entry_point.c_str()];
            EXPECT_NE([library newFunctionWithName:entry], nil)
                << "no function named " << stage.entry_point;
        }
    }

    // ---- 3. the gate accepts the scene
    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    // ---- 4. a real frame, drawn by render command encoders
    @autoreleasepool {
        id<MTLDevice>  device = MTLCreateSystemDefaultDevice();
        CAMetalLayer*  layer  = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender  render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        const uint32_t before_compile = render.ShaderUpdateDemandReasons();
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // Zero means "provably still", which is what lets on-demand updating
        // stop this scene's clock. It must therefore be DERIVED, never the
        // value left over when the analysis found nothing to look at.
        //
        // This fixture's shader binds no frame-varying uniform, so zero is the
        // right answer for it -- which is exactly why asserting only that is
        // worthless. The assertion that carries weight is the one above it: a
        // renderer whose graph has not been analysed must report
        // `UnknownInput`, because a caller must never be able to mistake "not
        // asked yet" for "nothing changes".
        EXPECT_TRUE(before_compile & wallpaper::vulkan::DynamicReason::UnknownInput)
            << "an unanalysed renderer reported " << before_compile
            << ", which a caller would read as a still scene";
        const uint32_t reasons = render.ShaderUpdateDemandReasons();
        EXPECT_EQ(reasons, 0u) << "reported reasons: " << reasons;

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }

        std::vector<uint8_t> pixels;
        uint32_t             width = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
        ASSERT_EQ(width, 384u);
        ASSERT_EQ(height, 256u);
        ASSERT_EQ(pixels.size(), width * height * 4u);

        // The author's fragment shader writes vec4(u, v, 0.25, 1). The scene
        // clears to black, so any pixel with a blue channel near 0.25 and a
        // non-zero red or green can only have come from that shader running.
        std::size_t shader_pixels = 0;
        for (std::size_t i = 0; i < pixels.size(); i += 4) {
            const auto r = pixels[i];
            const auto g = pixels[i + 1];
            const auto b = pixels[i + 2];
            if (b >= 55 && b <= 73 && (r > 8 || g > 8)) ++shader_pixels;
        }
        EXPECT_GT(shader_pixels, 1000u)
            << "the target holds no pixels the author's fragment shader could have produced";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, APerspectiveCameraDrawsThroughTheAuthoredShader)
{
    // A scene that last round was refused only for a perspective camera: the
    // same author card, drawn through `global_perspective` rather than the
    // ortho global camera. The shader writes clip from g_MVP, so a rotated
    // card must foreshorten -- left and right edges different heights -- which
    // is what rules out "orthographic plus a constant scale".
    const auto project = WriteFixture(root_ / "perspective-project", "0.30");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache-perspective", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    ASSERT_NE(loaded.scene->cameras["global_perspective"], nullptr);
    node->SetCamera("global_perspective");
    node->SetRotation(Eigen::Vector3f { 0.0f, 0.55f, 0.0f });

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer  = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();

        std::vector<uint8_t> pixels;
        uint32_t             width = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
        ASSERT_EQ(width, 384u);
        ASSERT_EQ(height, 256u);

        auto column_height = [&](uint32_t x) {
            int min_y = -1;
            int max_y = -1;
            for (uint32_t y = 0; y < height; ++y) {
                const std::size_t i = (static_cast<std::size_t>(y) * width + x) * 4;
                const auto        b = pixels[i + 2];
                if (b >= 65 && b <= 90) {
                    if (min_y < 0) min_y = static_cast<int>(y);
                    max_y = static_cast<int>(y);
                }
            }
            return min_y < 0 ? 0 : max_y - min_y + 1;
        };

        uint32_t left = 0;
        uint32_t right = width - 1;
        while (left < width && column_height(left) == 0) ++left;
        while (right > 0 && column_height(right) == 0) --right;
        ASSERT_LT(left, right) << "the perspective card produced no shader pixels";
        const int left_h  = column_height(left + (right - left) / 8);
        const int right_h = column_height(right - (right - left) / 8);
        EXPECT_NE(left_h, 0);
        EXPECT_NE(right_h, 0);
        EXPECT_GT(std::abs(left_h - right_h), 4)
            << "a rotated card under a perspective camera must foreshorten; left height "
            << left_h << " right height " << right_h;

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AnIntermediateTargetIsDrawnCopiedAndResampledInOneFrame)
{
    // The shape an effect chain lowers to: the author's layer drawn into an
    // intermediate at the author's own smaller size, that intermediate copied
    // into a link texture, and the link texture resampled onto the scene's
    // output. Every step reads what an earlier step in the SAME frame produced.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);

    // An author-sized effect buffer: half the canvas in each axis. Its size must
    // survive as its own, not be flattened to the output's.
    loaded.scene->renderTargets["_rt_effect_pingpong_a_0"] = SceneRenderTarget {
        .width  = 192,
        .height = 128,
    };

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        rg::RenderGraph graph;
        AddDraw(graph, node, "_rt_effect_pingpong_a_0", {});
        AddCopy(graph, "_rt_effect_pingpong_a_0", "_rt_link_1");
        AddCopy(graph, "_rt_link_1", std::string(SpecTex_Default));

        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();

        const auto shader_pixels = [](const std::vector<uint8_t>& pixels) {
            std::size_t count = 0;
            for (std::size_t i = 0; i < pixels.size(); i += 4) {
                const auto r = pixels[i];
                const auto g = pixels[i + 1];
                const auto b = pixels[i + 2];
                if (b >= 55 && b <= 73 && (r > 8 || g > 8)) ++count;
            }
            return count;
        };

        std::vector<uint8_t> intermediate;
        uint32_t             width  = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(
            render.ReadRenderTargetForTests("_rt_effect_pingpong_a_0", intermediate, width, height));
        // The author's own size, not the output's: flattening the two would
        // make this 384x256 and change every texel step the effect samples at.
        EXPECT_EQ(width, 192u);
        EXPECT_EQ(height, 128u);
        EXPECT_GT(shader_pixels(intermediate), 200u)
            << "the intermediate holds nothing the author's shader could have written";

        std::vector<uint8_t> linked;
        ASSERT_TRUE(render.ReadRenderTargetForTests("_rt_link_1", linked, width, height));
        EXPECT_EQ(width, 192u);
        EXPECT_EQ(height, 128u);
        EXPECT_EQ(linked, intermediate) << "the equal-sized copy is not a faithful copy";

        std::vector<uint8_t> output;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), output, width, height));
        EXPECT_EQ(width, 384u);
        EXPECT_EQ(height, 256u);
        // The resample used to be skipped silently, which left this target
        // holding whatever it was cleared to.
        EXPECT_GT(shader_pixels(output), 800u)
            << "the scaled copy did not carry the intermediate onto the output";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ADrawnFrameIsReportedAsPresentedAndLeavesTheFirstFrameFlagAlone)
{
    // `Scene::first_frame_ok` is the scene handler's, and the handler tells the
    // host a first frame exists on the edge where it sets it. A backend that
    // set the flag itself would satisfy that check before the handler ran, the
    // host would never hear about the frame, and a wallpaper drawing perfectly
    // well would be torn down when the startup deadline expired.
    const auto project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        id<MTLDevice>  device = MTLCreateSystemDefaultDevice();
        CAMetalLayer*  layer  = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(256, 128);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 256,
            .height               = 128,
            .render_width         = 256,
            .render_height        = 128,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        bool presented = false;
        ASSERT_TRUE(render.drawFrame(*loaded.scene, &presented)) << render.lastError();
        EXPECT_TRUE(presented) << "a frame was drawn but not reported as reaching the layer";
        EXPECT_FALSE(loaded.scene->first_frame_ok)
            << "the backend claimed the handler's first-frame flag, so the host would never be "
               "told this wallpaper started";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, RememberedPrepareFailureStopsTheBackendFlipFlopping)
{
    const auto project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    RecordMetalPrepareFailure(*loaded.scene, "a shader pipeline could not be created");
    for (int attempt = 0; attempt < 3; ++attempt) {
        const auto selection = SelectSceneBackend(*loaded.scene);
        EXPECT_EQ(selection.backend, SceneBackend::LegacyVulkan);
        EXPECT_EQ(selection.fallback_reason, "a shader pipeline could not be created");
    }

    // Turning the preference off and on again is the one thing the user can do
    // that makes the question worth asking a second time.
    SetSceneRendererPreference(SceneRendererPreference::Compatibility);
    const auto off = SelectSceneBackend(*loaded.scene);
    EXPECT_EQ(off.backend, SceneBackend::LegacyVulkan);
    EXPECT_TRUE(off.fallback_reason.empty()) << "choosing compatibility is not a fallback";

    SetSceneRendererPreference(SceneRendererPreference::NativeMetalPreferred);
    EXPECT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);
}


// ---------------------------------------------------------------------------
// Scene optimisation on the native backend

namespace
{

/// A drawn frame plus the reuse counters that frame moved.
struct FrameCounters
{
    uint64_t executed { 0 };
    uint64_t skipped { 0 };
};

FrameCounters DrawOneFrame(MetalRender& render, Scene& scene)
{
    const auto before = wallpaper::vulkan::CurrentSceneOptimizationTotals();
    const bool ok     = render.drawFrame(scene);
    EXPECT_TRUE(ok) << render.lastError();
    const auto after = wallpaper::vulkan::CurrentSceneOptimizationTotals();
    return FrameCounters { after.executed_passes - before.executed_passes,
                           after.skipped_passes - before.skipped_passes };
}

std::vector<uint8_t> ReadOutput(MetalRender& render, Scene& scene)
{
    std::vector<uint8_t> pixels;
    uint32_t             width = 0;
    uint32_t             height = 0;
    EXPECT_TRUE(render.ReadRenderTargetForTests(scene.ResolveRenderTargetName(SpecTex_Default),
                                                pixels, width, height));
    return pixels;
}

} // namespace

TEST_F(MetalSceneDraw, AnUnchangedTargetIsReusedAndProducesTheSamePixels)
{
    // This fixture binds no frame-varying uniform, which is exactly the scene
    // whose second frame has nothing new to draw. What must be true is both
    // halves at once: work was removed, AND the picture is byte-identical to
    // the one the work produced.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        const auto first = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(first.skipped, 0u) << "nothing can be reused before anything has been drawn";
        EXPECT_GT(first.executed, 0u);
        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());

        const auto second = DrawOneFrame(render, *loaded.scene);
        EXPECT_GT(second.skipped, 0u)
            << "an unchanged scene re-executed every pass; nothing was reused";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), drawn)
            << "the reused target does not hold the pixels the drawn frame produced";

        // Moving the layer changes the model transform, which is part of the
        // sample. The target has to be redrawn, and the picture has to change.
        auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
        ASSERT_NE(node, nullptr);
        node->SetTranslate(Eigen::Vector3f { 96.0f, 64.0f, 0.0f });
        const auto moved = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(moved.skipped, 0u)
            << "a moved layer reused its target; the transform is not in the sample";
        EXPECT_NE(ReadOutput(render, *loaded.scene), drawn)
            << "the target was re-executed but the picture did not change";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TurningTheOptimisationOffDrawsEveryPassAgain)
{
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        wallpaper::vulkan::SetSceneOptimizationEnabled(false);
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        DrawOneFrame(render, *loaded.scene);
        const auto second = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(second.skipped, 0u) << "pixels were reused with the setting switched off";
        wallpaper::vulkan::SetSceneOptimizationEnabled(true);

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, GeometryRebuiltEveryFrameIsUploadedAndDrawnFromItsOwnSlot)
{
    // The particle shape, without a particle system: a mesh marked dynamic,
    // empty when the graph is compiled, filled afterwards. What is proved is
    // the upload path -- an empty frame is not a failure, a filled one reaches
    // the screen, and the storage rotates per in-flight frame without the CPU
    // overwriting what the GPU is reading.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);

    // Same attribute names the author's shader declares, so the translated
    // pipeline binds this stream exactly as it binds the static one.
    auto dynamic_mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 },
    };
    constexpr std::size_t kQuads = 4;
    dynamic_mesh->AddVertexArray(SceneVertexArray(attributes, kQuads * 4));
    dynamic_mesh->AddIndexArray(SceneIndexArray(kQuads));
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_SPRITE, true);
    dynamic_mesh->MaterialSlots().push_back(material);
    node->AddMesh(dynamic_mesh);

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // A mesh the runtime has not filled yet must keep the scene ticking
        // rather than be declared still, and must not be reusable.
        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::DynamicMesh)
            << "a mesh rebuilt per frame was not reported as advancing on its own";

        // Three empty frames: nothing to draw is not a failed frame.
        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto empty = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(empty.empty());

        // Now fill one quad, the way the particle generator does, and let more
        // than `kFramesInFlight` frames go by so every slot is written and read.
        auto& vertices = dynamic_mesh->GetVertexArray(0);
        auto& indices  = dynamic_mesh->GetIndexArray(0);
        const std::array<float, 20> quad {
            20.0f,  20.0f,  0.0f, 0.0f, 0.0f,
            360.0f, 20.0f,  0.0f, 1.0f, 0.0f,
            360.0f, 230.0f, 0.0f, 1.0f, 1.0f,
            20.0f,  230.0f, 0.0f, 0.0f, 1.0f,
        };
        vertices.SetVertexs(0, quad);
        const std::array<uint16_t, 6> quad_indices { 0, 1, 3, 1, 2, 3 };
        indices.AssignHalf(0, quad_indices);
        indices.SetRenderDataCount(3);
        dynamic_mesh->SetDirty();

        for (int frame = 0; frame < 5; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto filled = ReadOutput(render, *loaded.scene);
        EXPECT_NE(filled, empty)
            << "geometry uploaded after the graph was compiled never reached the target";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ASpriteSheetAdvancesOnItsOwnClockAndRedrawsOnlyWhenTheFrameChanges)
{
    // Sprite animation reaches the shader as the frame's rotation and
    // translation uniforms, so what has to be proved is the chain around them:
    // the sheet is picked up at prepare, advanced by the shared value updater
    // every frame, folded into the reuse sample as the rectangle that will
    // actually be sampled, and reported as something that keeps the clock
    // running. The fixture's shader binds no texture slot, so nothing here
    // claims a sheet was sampled on the GPU -- only that the machinery around
    // it behaves.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);

    // Two frames of one sheet, a tenth of a second apart.
    SceneTexture sheet { .url = "materials/sheet.tex", .isSprite = true };
    sheet.spriteAnim.AppendFrame(
        SpriteFrame { .imageId = 0, .frametime = 0.1f, .width = 0.5f, .height = 1.0f });
    sheet.spriteAnim.AppendFrame(SpriteFrame {
        .imageId = 0, .frametime = 0.1f, .x = 0.5f, .width = 0.5f, .height = 1.0f });
    loaded.scene->textures["materials/sheet.tex"] = std::move(sheet);
    material->textures = { "materials/sheet.tex" };

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // A sheet with more than one frame is not a still scene: whatever the
        // reuse cache decides, the clock has to keep running or the animation
        // never reaches its next frame.
        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::AnimatedSprite)
            << "an animated sheet was not reported as advancing on its own";

        DrawOneFrame(render, *loaded.scene);
        // A sheet starts with no time left on its current frame, so the first
        // tick that carries any elapsed time steps it. That step has to redraw.
        loaded.scene->PassFrameTime(1.0 / 60.0);
        const auto first_step = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(first_step.skipped, 0u)
            << "the sheet stepped to its second frame and the target was reused anyway";

        // A sixtieth of a second does not consume the tenth of a second this
        // frame is held for, so the rectangle the shader samples is unchanged
        // and the target may be reused.
        const auto between = DrawOneFrame(render, *loaded.scene);
        EXPECT_GT(between.skipped, 0u) << "a sheet between frame changes forced a redraw";

        // Enough time to step the sheet again: the rectangle changes, so the
        // target must be redrawn rather than reused. The clock kept running
        // through the reused frames above, which is what makes this reachable.
        loaded.scene->PassFrameTime(0.5);
        const auto stepped = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(stepped.skipped, 0u)
            << "the sheet advanced a frame and the target was reused anyway";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TurningTheOptimisationBackOnDoesNotReuseAFrameDrawnWhileItWasOff)
{
    // The defect this covers: with reuse off, nothing records a signature, so
    // the table keeps the one that was current when it was switched off -- while
    // every frame in between redraws from whatever inputs it has. If the inputs
    // later return to that recorded value, re-enabling would call the target
    // unchanged although its pixels came from a frame with different inputs.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    const Eigen::Vector3f home = node->Translate();

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        DrawOneFrame(render, *loaded.scene);
        const auto at_home = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(at_home.empty());
        ASSERT_GT(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "the recorded signature this test depends on was never taken";

        // Off: the layer moves and is drawn there. Nothing records that.
        wallpaper::vulkan::SetSceneOptimizationEnabled(false);
        node->SetTranslate(Eigen::Vector3f { home.x() + 96.0f, home.y(), home.z() });
        const auto moved = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(moved.skipped, 0u) << "pixels were reused with the setting switched off";
        const auto away = ReadOutput(render, *loaded.scene);
        ASSERT_NE(away, at_home);

        // Back to where the recorded signature was taken, without drawing: the
        // target still holds the moved picture.
        node->SetTranslate(home);
        wallpaper::vulkan::SetSceneOptimizationEnabled(true);

        const auto resumed = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(resumed.skipped, 0u)
            << "re-enabling reused a target whose pixels came from a frame drawn while it was off";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), at_home)
            << "the first frame after re-enabling did not restore the picture its inputs describe";

        // And it records again from there.
        EXPECT_GT(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "reuse never resumed after the setting was switched back on";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AGraphCompiledWithTheOptimisationOffStartsReusingWhenItIsTurnedOn)
{
    // The asymmetry this removes: the reuse table, the copy plan and the target
    // table are all built while the graph is compiled, so a graph compiled with
    // the setting off used to carry no plan at all and turning the setting back
    // on did nothing until the wallpaper, the render scale or the app changed.
    // Nothing here recompiles the graph; the change is applied at a frame
    // boundary over the graph that is already running.
    wallpaper::vulkan::SetSceneOptimizationEnabled(false);
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        // Compiled with the setting off: no reuse table exists at this point.
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "pixels were reused although the graph was compiled with the setting off";
        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());

        wallpaper::vulkan::SetSceneOptimizationEnabled(true);
        // The first frame after the change redraws: a table that has recorded
        // nothing cannot call anything unchanged, which is what stops stale
        // pixels being adopted.
        EXPECT_EQ(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "the first frame after re-enabling reused pixels no plan had recorded";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), drawn)
            << "re-applying the setting changed the picture";
        // And from there it reuses, without the graph having been compiled
        // again.
        EXPECT_GT(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "re-enabling never produced a reuse plan for the running graph";

        render.destroy();
    }
}

// ---------------------------------------------------------------------------
// A real video layer, through the whole path.
//
// This is what makes the direct plane path more than a compiler feature: an
// ordinary author project whose material samples `g_Texture0`, a real decoded
// video behind that slot, the second program compiled by the parser from the
// same inputs as the first, the planes bound through the binding plan
// reflection produced, and the picture read back off the GPU. Nothing here is a
// test-only shader: the fragment source below is what the author wrote and it
// is what draws.

namespace
{

/// The media the fixtures name. 640x360, because the comparison below has to be
/// able to ask for a one-to-one mapping between video texels and output pixels.
constexpr uint32_t kVideoWidth  = 640;
constexpr uint32_t kVideoHeight = 360;

/// The same fixture shape as the cases above, with one video texture on slot 0
/// and a material that samples it the way an ordinary image layer does.
///
/// `canvas` sizes both the orthographic projection and the layer, so a fixture
/// at the media's own size maps one video texel onto one output pixel and a
/// smaller one exercises the scaled case.
std::filesystem::path WriteVideoFixture(const std::filesystem::path& root, uint32_t canvas_width,
                                        uint32_t canvas_height)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    // A plain sample of the layer's own texture, which is what the large
    // majority of image-layer shaders do.
    const std::string fragment =
        "uniform sampler2D g_Texture0;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_FragColor = texture2D(g_Texture0, v_TexCoord);\n"
        "}\n";

    const std::string width  = std::to_string(canvas_width);
    const std::string height = std::to_string(canvas_height);
    const std::string origin_x = std::to_string(canvas_width / 2);
    const std::string origin_y = std::to_string(canvas_height / 2);

    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal video draw","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        { "models/tile.json",
          R"({"width":)" + width + R"(,"height":)" + height +
              R"(,"material":"materials/tile.json"})" },
        { "materials/tile.json",
          R"({"passes":[{"shader":"metal_video","blending":"normal","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":["clip"]}]})" },
        { "shaders/metal_video.vert", vertex },
        { "shaders/metal_video.frag", fragment },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":)" +
              width + R"(,"height":)" + height + R"(}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[)" +
              origin_x + "," + origin_y + R"(,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    // The media the material's texture slot names, encoded here rather than
    // shipped. `clip.mp4` is what the loose-asset resolver finds for "clip".
    std::filesystem::create_directories(root / "materials");
    if (! video::testing_media::WriteSyntheticVideo(root / "materials" / "clip.mp4", 1,
                                                    "metal-video-draw")) {
        return {};
    }
    return root / "project.json";
}

/// One offscreen native renderer over a compiled graph, at `width`x`height`.
struct VideoScene {
    LoadedScene     loaded;
    CAMetalLayer*   layer { nil };
    MetalRender     render;
    std::unique_ptr<rg::RenderGraph> graph;

    bool Draw() { return render.drawFrame(*loaded.scene); }

    std::vector<uint8_t> Read()
    {
        std::vector<uint8_t> pixels;
        uint32_t             width  = 0;
        uint32_t             height = 0;
        if (! render.ReadRenderTargetForTests(
                loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height)) {
            ADD_FAILURE() << "the scene output could not be read back";
        }
        return pixels;
    }
};

} // namespace

/// Restores the process-wide switch however a test leaves.
namespace
{
struct ScopedPlaneSampling {
    explicit ScopedPlaneSampling(bool enabled) { SetMetalVideoPlaneSamplingEnabled(enabled); }
    ~ScopedPlaneSampling() { SetMetalVideoPlaneSamplingEnabled(false); }
};
} // namespace

TEST_F(MetalSceneDraw, AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader)
{
    const auto project = WriteVideoFixture(root_ / "video-project", kVideoWidth, kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "video-cache", loaded, error)) << error;

    auto* material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->error.empty()) << program->error;

    // ---- 1. the parser captured what a second program would need, and
    // compiled nothing: loading a wallpaper must not pay for an optional
    // program before it has drawn a frame.
    ASSERT_TRUE(program->hasVideoPlaneCandidate())
        << "no plane variant was even possible for a single-video material";
    ASSERT_EQ(program->videoPlaneState(), SceneMetalVariantState::None)
        << "the optional program was compiled during the parse";

    // ---- 2. asked for, it is produced in the background from that snapshot
    std::string variant_error;
    ASSERT_TRUE(SettleVariantTranslation(*loaded.scene, &variant_error)) << variant_error;
    const auto variant = program->videoPlanes();
    ASSERT_NE(variant, nullptr);
    ASSERT_TRUE(variant->ok()) << "plane variant refused: " << variant->error;
    EXPECT_EQ(variant->slot, 0u);
    ASSERT_FALSE(variant->stages.empty());
    // A translation of the author's program, not a substitute for it.
    EXPECT_NE(variant->stages.front().source, program->stages.front().source);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    // ---- 3. a real frame, drawn through the variant
    ScopedPlaneSampling sampling(true);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(kVideoWidth, kVideoHeight);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = kVideoWidth,
            .height               = kVideoHeight,
            .render_width         = kVideoWidth,
            .render_height        = kVideoHeight,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        // The optional pipeline is built off the frame thread, so the adoption
        // happens at the first boundary after it comes back rather than at the
        // first frame. A few more frames is what that looks like from here.
        DrawUntilVideoPath(render, *loaded.scene, SceneVideoPath::Nv12Direct);

        // ---- 4. the path the frame really took
        const auto path = render.VideoPath();
        if (path != SceneVideoPath::Nv12Direct) {
            // Software decode hands back BGRA, and the direct path is then not
            // applicable rather than broken. Reported rather than asserted
            // away, because a machine without VideoToolbox is a real one.
            GTEST_SKIP() << "the decoder produced " << SceneVideoPathName(path)
                         << " rather than NV12, so the direct path was not exercised";
        }

        std::vector<uint8_t> pixels;
        uint32_t             width  = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
        ASSERT_EQ(pixels.size(), width * height * 4u);

        // The scene clears to black, so a frame carrying colour is a frame the
        // plane sample produced.
        std::size_t coloured = 0;
        for (std::size_t i = 0; i < pixels.size(); i += 4) {
            if (pixels[i] > 8 || pixels[i + 1] > 8 || pixels[i + 2] > 8) ++coloured;
        }
        EXPECT_GT(coloured, 1000u)
            << "the output holds nothing the plane sample could have produced";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AVideoLayerKeepsConvertingWhileTheSettingIsOff)
{
    const auto project = WriteVideoFixture(root_ / "video-off-project", kVideoWidth, kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "video-off-cache", loaded, error)) << error;

    // Default state, asserted rather than assumed: the material could have a
    // variant and, with the switch off, none is asked for at all.
    ScopedPlaneSampling sampling(false);
    auto* off_material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(off_material, nullptr);
    ASSERT_NE(off_material->customShader.shader, nullptr);
    const auto off_program = off_material->customShader.shader->metal_program;
    ASSERT_NE(off_program, nullptr);
    ASSERT_TRUE(off_program->hasVideoPlaneCandidate());

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(kVideoWidth, kVideoHeight);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = kVideoWidth,
            .height               = kVideoHeight,
            .render_width         = kVideoWidth,
            .render_height        = kVideoHeight,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }

        const auto path = render.VideoPath();
        EXPECT_NE(path, SceneVideoPath::Nv12Direct)
            << "the switch is off and a material still sampled planes";
        EXPECT_NE(path, SceneVideoPath::Nv12Mixed);
        // Nothing was translated and nothing was built. This is the whole point
        // of the switch being off: it is not "compiled and unused", it is "not
        // compiled".
        EXPECT_EQ(off_program->videoPlaneState(), SceneMetalVariantState::None)
            << "an optional program was prepared although the switch was off";

        // And switching it on reaches a scene that is already running, without
        // the graph being compiled again. The wallpaper's own loop asks at a
        // frame boundary; this drives the renderer directly, so it asks here.
        SetMetalVideoPlaneSamplingEnabled(true);
        std::string variant_error;
        if (path == SceneVideoPath::Nv12Converted) {
            ASSERT_TRUE(SettleVariantTranslation(*loaded.scene, &variant_error)) << variant_error;
            EXPECT_TRUE(DrawUntilVideoPath(render, *loaded.scene, SceneVideoPath::Nv12Direct))
                << "a running scene never picked the setting up";
        }

        render.destroy();
    }
}

namespace
{

/// Draws one decoded frame twice -- once pre-converted, once sampled directly --
/// and returns the per-channel differences.
///
/// The frame is held by pausing playback, and the hold is proved rather than
/// assumed: two draws on the same path must reproduce each other before the
/// two paths are compared at all.
struct PathComparison {
    bool                 ran { false };
    std::string          skip_reason;
    std::vector<uint8_t> converted;
    std::vector<uint8_t> direct;
};

PathComparison CompareVideoPaths(const std::filesystem::path& project,
                                 const std::filesystem::path& cache, uint32_t canvas_width,
                                 uint32_t canvas_height)
{
    PathComparison result;
    LoadedScene    loaded;
    std::string    error;
    if (! LoadScene(project, cache, loaded, error)) {
        result.skip_reason = error;
        return result;
    }

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(canvas_width, canvas_height);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = static_cast<uint16_t>(canvas_width),
            .height               = static_cast<uint16_t>(canvas_height),
            .render_width         = static_cast<uint16_t>(canvas_width),
            .render_height        = static_cast<uint16_t>(canvas_height),
            .display_scale_factor = 1.0,
        };
        if (! render.init(info)) {
            result.skip_reason = render.lastError();
            return result;
        }
        auto graph = sceneToRenderGraph(*loaded.scene);
        if (graph == nullptr || ! render.compileRenderGraph(*loaded.scene, *graph)) {
            result.skip_reason = render.lastError();
            return result;
        }
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        const auto output = loaded.scene->ResolveRenderTargetName(SpecTex_Default);
        const auto read   = [&]() {
            std::vector<uint8_t> pixels;
            uint32_t             width  = 0;
            uint32_t             height = 0;
            render.ReadRenderTargetForTests(output, pixels, width, height);
            return pixels;
        };

        SetMetalVideoPlaneSamplingEnabled(false);
        for (int frame = 0; frame < 2; ++frame) {
            if (! render.drawFrame(*loaded.scene)) {
                result.skip_reason = render.lastError();
                return result;
            }
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        render.SetVideoPlaybackPaused(true);
        // Pausing stops the clock, but frames the decoder had already produced
        // still become current one at a time. The hold is therefore waited for
        // and then proved, rather than assumed after a fixed number of frames:
        // two consecutive draws reproducing each other exactly is the only
        // evidence that what follows compares one frame.
        std::vector<uint8_t> previous;
        bool                 held = false;
        for (int settle = 0; settle < 16 && ! held; ++settle) {
            if (! render.drawFrame(*loaded.scene)) {
                result.skip_reason = render.lastError();
                return result;
            }
            auto current = read();
            held         = ! previous.empty() && current == previous;
            previous     = std::move(current);
        }
        if (! held) {
            result.skip_reason = "the decoded frame never stopped advancing while paused";
            return result;
        }
        if (render.VideoPath() != SceneVideoPath::Nv12Converted) {
            result.skip_reason = std::string("the decoder produced ") +
                                 SceneVideoPathName(render.VideoPath()) +
                                 ", so there is no conversion to compare against";
            return result;
        }
        result.converted = std::move(previous);

        SetMetalVideoPlaneSamplingEnabled(true);
        std::string variant_error;
        if (! SettleVariantTranslation(*loaded.scene, &variant_error)) {
            result.skip_reason = variant_error;
            return result;
        }
        // Without advancing the clock: the frame is held, and what is being
        // waited for is the optional pipeline, not a new picture.
        if (! DrawUntilVideoPath(render, *loaded.scene, SceneVideoPath::Nv12Direct)) {
            result.skip_reason = "the running scene did not take the direct path";
            return result;
        }
        result.direct = read();
        result.ran    = result.converted.size() == result.direct.size() &&
                     ! result.converted.empty();
        render.destroy();
    }
    return result;
}

} // namespace

TEST_F(MetalSceneDraw, OneToOneSamplingProducesTheSamePictureOnBothPaths)
{
    // The equivalence claim, measured rather than asserted in prose: one decoded
    // frame, held still, drawn by the pre-converting program and then by the
    // plane-sampling one, at a size where one video texel maps to one output
    // pixel.
    //
    // One code value is the intermediate's own 8-bit quantisation, which the
    // direct path does not perform. Anything larger would be a real difference
    // in the picture.
    const auto project =
        WriteVideoFixture(root_ / "video-1to1-project", kVideoWidth, kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    ScopedPlaneSampling sampling(false);
    const auto comparison =
        CompareVideoPaths(project, root_ / "video-1to1-cache", kVideoWidth, kVideoHeight);
    if (! comparison.ran) GTEST_SKIP() << comparison.skip_reason;

    int worst = 0;
    for (std::size_t i = 0; i < comparison.converted.size(); ++i) {
        worst = std::max(worst, std::abs(static_cast<int>(comparison.converted[i]) -
                                          static_cast<int>(comparison.direct[i])));
    }
    EXPECT_LE(worst, 1) << "the two paths disagree by " << worst
                        << " code values at a one-to-one mapping";
}

TEST_F(MetalSceneDraw, ScaledSamplingStaysInsideTheClampExcursionTheStreamImplies)
{
    // Where the layer is resampled, the two paths stop being identical, and the
    // reason is structural rather than numerical. The pre-converting path
    // clamps each texel to the stream's declared range and quantises it before
    // the author's sampler filters; the direct path filters first and clamps
    // the result. The transform between those two clamps is affine, so the two
    // orders agree exactly wherever the clamp does nothing -- which is every
    // sample a conforming stream carries.
    //
    // Where a stream does carry codes outside the range it declares, the two
    // orders disagree by at most the excursion the clamp removes. For 8-bit
    // limited range that is (255 - 235) / 219 * 255 = 23.3 code values at the
    // top and 16 / 219 * 255 = 18.6 at the bottom, so 24 bounds it. The
    // synthetic probe below is deliberately the worst case: full-range noise
    // carried in a stream that declares limited range, so roughly one texel in
    // seven clamps. Real content does not look like this, which is why the
    // one-to-one case above is the equivalence claim and this one is a bound.
    constexpr int kClampExcursionBound = 24;

    const auto project = WriteVideoFixture(root_ / "video-scaled-project", 384, 256);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    ScopedPlaneSampling sampling(false);
    const auto comparison = CompareVideoPaths(project, root_ / "video-scaled-cache", 384, 256);
    if (! comparison.ran) GTEST_SKIP() << comparison.skip_reason;

    int       worst = 0;
    long long total = 0;
    for (std::size_t i = 0; i < comparison.converted.size(); ++i) {
        const int delta = std::abs(static_cast<int>(comparison.converted[i]) -
                                    static_cast<int>(comparison.direct[i]));
        worst = std::max(worst, delta);
        total += delta;
    }
    const double mean = static_cast<double>(total) /
                        static_cast<double>(comparison.converted.size());

    EXPECT_LE(worst, kClampExcursionBound)
        << "the two paths disagree by " << worst
        << " code values, which is more than the stream's own clamp can account for";
    // A colour, binding or coordinate fault would not stay near zero on
    // average, whatever it did to the worst pixel.
    EXPECT_LT(mean, 3.0) << "the two paths differ by " << mean
                         << " code values on average, which is a picture difference rather than "
                            "a clamp-order effect at the edges";
    RecordProperty("worst_delta", worst);
}

namespace
{

/// A project whose only layer is a text object, in the shape the editor's "add
/// text" writes: no model, no material, no author shader. Everything the layer
/// draws with -- the card, its texture and the program that samples it -- is
/// produced by the parser and the text system.
///
/// `text_json`, when given, replaces the quoted caption with the author's own
/// JSON for that field: `{"user":...}` for a layer the user's property drives,
/// `{"script":...}` for one that re-evaluates itself every tick.
std::filesystem::path WriteTextFixture(const std::filesystem::path& root, std::string_view text,
                                       bool with_effect = false,
                                       std::string_view text_json = {})
{
    const std::string effects =
        with_effect ? R"(,"effects":[{"file":"effects/probe.json","visible":true}])" : "";
    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal text smoke","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        // An effect chain over the text layer: the layer draws into a buffer,
        // the effect samples it, and the chain's final card -- a second mesh the
        // relayout rewrites -- draws the result.
        { "effects/probe.json",
          R"({"name":"probe copy","passes":[{"material":"materials/copy.json"}]})" },
        { "materials/copy.json",
          R"({"passes":[{"shader":"probe_copy","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})" },
        { "shaders/probe_copy.vert",
          "uniform mat4 g_ModelViewProjectionMatrix;\n"
          "attribute vec3 a_Position;\n"
          "attribute vec2 a_TexCoord;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
          "  v_TexCoord = a_TexCoord;\n"
          "}\n" },
        { "shaders/probe_copy.frag",
          "uniform sampler2D g_Texture0;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  gl_FragColor = texture(g_Texture0, v_TexCoord);\n"
          "}\n" },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"caption","text":)" +
              (text_json.empty() ? "\"" + std::string(text) + "\"" : std::string(text_json)) +
              R"(,"font":"Arial","pointsize":48,"origin":[192,128,0],)"
              R"("scale":[1,1,1],"angles":[0,0,0],"visible":true)" + effects + R"(}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return root / "project.json";
}

/// How many pixels carry colour, which is the only thing that distinguishes
/// "the glyphs were drawn" from "the pass ran".
///
/// Colour, not alpha: a cleared opaque black target has alpha everywhere and
/// would satisfy a test that counted it.
std::size_t LitPixels(const std::vector<uint8_t>& rgba)
{
    std::size_t lit = 0;
    for (std::size_t i = 0; i + 3 < rgba.size(); i += 4) {
        if (rgba[i] != 0 || rgba[i + 1] != 0 || rgba[i + 2] != 0) ++lit;
    }
    return lit;
}

/// Exactly what `SceneWallpaper::evaluateSceneUpdateDemand` ORs to decide
/// whether a scene may stop its clock, assembled from the same two halves so
/// this can be asked without a frame clock, a looper or a surface.
uint32_t SceneDemand(MetalRender& render, Scene& scene)
{
    uint32_t reasons = SceneDemandReasonsFromShaderInputs(render.ShaderUpdateDemandReasons());
    if (scene.runtime != nullptr) reasons |= scene.runtime->DescribeTimeAdvancingWork();
    return reasons;
}

/// One production frame: the runtime tick and the text pump the wallpaper's own
/// loop runs, then the draw.
void AdvanceSceneFrame(MetalRender& render, Scene& scene)
{
    if (scene.runtime != nullptr) {
        scene.runtime->Tick(1.0 / 60.0);
        scene.runtime->PumpTextLayerCache();
    }
    EXPECT_TRUE(render.drawFrame(scene)) << render.lastError();
    scene.PassFrameTime(1.0 / 60.0);
}

} // namespace

TEST_F(MetalSceneDraw, ATextLayerIsParsedTranslatedAndDrawnByTheNativeBackend)
{
    // The whole chain for a text layer, through the ordinary parser and the
    // production graph lowering: the card the runtime rewrites is accepted, the
    // text program is translated to Metal, the rasterised glyphs are imported as
    // an ordinary image and the layer reaches the scene's own output.
    const auto  project = WriteTextFixture(root_ / "text-project", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) AdvanceSceneFrame(render, *loaded.scene);

        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());
        EXPECT_GT(LitPixels(drawn), 0u)
            << "the text layer produced no pixels in the scene's own target";

        // A layer whose picture the runtime replaces must keep the clock
        // running, or a text that changes would never be redrawn.
        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::RuntimeImage)
            << "a runtime-replaced image was not reported as a reason to keep drawing";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain)
{
    // The round's optimisation, stated as what must NOT happen: the scripts and
    // the runtime keep running every frame, and the same string must still cost
    // no measurement, no rasterisation and no texture upload. Then a real change
    // must cost exactly those, once.
    const auto  project = WriteTextFixture(root_ / "text-repeat-project", "12:30");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // Settle: the first layout is prepared on the text worker, so the
        // uploads it produces belong to start-up rather than to steady state.
        for (int frame = 0; frame < 8; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        const auto settled         = ReadOutput(render, *loaded.scene);
        const auto settled_uploads = render.RuntimeImageUploadsForTests();
        ResetTextLayerMeasurementCountForTests();

        for (int frame = 0; frame < 12; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        EXPECT_EQ(render.RuntimeImageUploadsForTests(), settled_uploads)
            << "an unchanged text was uploaded to the GPU again";
        EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u)
            << "an unchanged text was measured and laid out again";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), settled);

        // The same layer, a different string: the work that was skipped above
        // has to happen now, and the picture has to change with it.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "12:31"));
        std::vector<uint8_t> changed;
        for (int frame = 0; frame < 16; ++frame) {
            AdvanceSceneFrame(render, *loaded.scene);
            changed = ReadOutput(render, *loaded.scene);
            if (changed != settled) break;
        }
        EXPECT_NE(changed, settled) << "a new string never reached the drawn picture";
        const auto changed_uploads = render.RuntimeImageUploadsForTests();
        EXPECT_GT(changed_uploads, settled_uploads);
        // One write per in-flight slot at most: new pixels go into the storage
        // the frame owns, never into an image a queued command buffer reads.
        EXPECT_LE(changed_uploads - settled_uploads, 2u)
            << "one text change caused more uploads than there are frames in flight";

        // And back to quiet: once every in-flight slot holds the new picture,
        // the new string is the unchanged one and costs nothing again.
        for (int frame = 0; frame < 4; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        const auto quiet_uploads = render.RuntimeImageUploadsForTests();
        for (int frame = 0; frame < 12; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        EXPECT_EQ(render.RuntimeImageUploadsForTests(), quiet_uploads)
            << "a text that had already settled kept uploading";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TheSameProgramIsCompiledOnceAndReusedByTheNextSurface)
{
    // Two renderers, the same wallpaper, one device. The second one must find
    // the translated program already compiled: a second surface showing what is
    // already on screen is the ordinary case -- the lock screen beside the
    // desktop, a preview beside the wallpaper -- and paying the Metal compiler
    // again for the identical source is pure duplicated work.
    // A constant no other fixture uses, so the first load below is a genuine
    // cold compile rather than a hit left by an earlier test in this process.
    const auto project = WriteFixture(root_ / "reuse-project", "0.3125");

    const auto draw_once = [&](const std::filesystem::path& cache) {
        LoadedScene loaded;
        std::string error;
        EXPECT_TRUE(LoadScene(project, cache, loaded, error)) << error;
        if (loaded.scene == nullptr) return;

        @autoreleasepool {
            id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = device;
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 384,
                .height               = 256,
                .render_width         = 384,
                .render_height        = 256,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            render.destroy();
        }
    };

    const auto before_first = MetalRender::ProgramCompilesForTests();
    draw_once(root_ / "reuse-cache-a");
    const auto after_first = MetalRender::ProgramCompilesForTests();
    // The first one has to compile something, or the comparison below would be
    // satisfied by a counter nothing increments.
    ASSERT_GT(after_first, before_first)
        << "nothing was handed to the Metal compiler, so nothing could be reused";

    draw_once(root_ / "reuse-cache-b");
    EXPECT_EQ(MetalRender::ProgramCompilesForTests(), after_first)
        << "the same translated program was compiled by Metal a second time";
}

TEST_F(MetalSceneDraw, ATextLayerWithAnEffectChainKeepsBothOfItsCards)
{
    // A text layer with effects has more than one mesh the relayout rewrites:
    // its own card, the chain's final card, and the node the chain resolves its
    // last pass onto. All three are the same four-corner shape, and the gate has
    // to accept all three or the scene falls back as a whole.
    const auto  project = WriteTextFixture(root_ / "text-effect-project", "EFFECT", true);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "text-effect-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 4; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());
        EXPECT_GT(LitPixels(drawn), 0u)
            << "the text layer's effect chain produced no pixels in the scene's own target";
        // And the chain's cards follow a relayout rather than keeping the size
        // the first frame was built at. Different glyphs, not more of the same
        // word: the chain draws into a buffer the layer's card is clipped to,
        // and a longer repetition can leave exactly the same pixels inside it.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        std::vector<uint8_t> changed;
        for (int frame = 0; frame < 16; ++frame) {
            AdvanceSceneFrame(render, *loaded.scene);
            changed = ReadOutput(render, *loaded.scene);
            if (changed != drawn) break;
        }
        EXPECT_NE(changed, drawn) << "a relayout never reached the effect chain's output";

        render.destroy();
    }
}

namespace
{

/// Draws until the scene reports it has nothing left to do, or gives up.
///
/// Bounded on purpose: "eventually quiet" is the claim, and a test that spun
/// forever would turn a scene that never settles into a hang rather than a
/// failure.
bool SettleSceneDemand(MetalRender& render, Scene& scene, int max_frames = 120)
{
    for (int frame = 0; frame < max_frames; ++frame) {
        AdvanceSceneFrame(render, scene);
        if (SceneDemand(render, scene) == 0) return true;
    }
    return false;
}

} // namespace

TEST_F(MetalSceneDraw, AStaticTextSceneRunsOutOfWorkToDo)
{
    // The round's point, stated as the scene's own answer: a text layer whose
    // caption is fixed has nothing that advances on its own, so the wallpaper
    // may stop its clock entirely rather than merely stop uploading.
    const auto  project = WriteTextFixture(root_ / "static-text-idle", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "static-text-idle-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "a fixed caption never stopped asking for frames";
        EXPECT_GT(LitPixels(ReadOutput(render, *loaded.scene)), 0u)
            << "the scene went quiet without ever drawing the text";

        // Both facts that used to stop it are still reported, because both are
        // still true and the pixel-reuse cache depends on them. What changed is
        // that neither is read as a reason for the whole scene to keep drawing.
        const auto shader = render.ShaderUpdateDemandReasons();
        EXPECT_TRUE(shader & wallpaper::vulkan::DynamicReason::EventMesh)
            << "the text card stopped being reported as geometry the runtime rewrites";
        EXPECT_TRUE(shader & wallpaper::vulkan::DynamicReason::RuntimeImage)
            << "the text texture stopped being reported as an image the runtime replaces";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AChangedCaptionWakesTheSceneAndThenLetsItGoQuietAgain)
{
    // The other half of idling, and the one that makes it safe: a scene that
    // has gone quiet must not stay quiet through a change. The demand has to
    // come back while the new layout is in flight, the new picture has to
    // reach the output, and only then may the scene be still again.
    const auto  project = WriteTextFixture(root_ / "text-wake", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "text-wake-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene));
        const auto quiet = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(quiet.empty());

        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        EXPECT_NE(SceneDemand(render, *loaded.scene), 0u)
            << "a caption that changed left the scene claiming it had nothing to do";

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "the scene never finished applying the new caption";
        EXPECT_NE(ReadOutput(render, *loaded.scene), quiet)
            << "the scene went quiet again without the new caption reaching the output";

        // Setting the same string back is not a change, so it must not produce
        // a scene that thinks it has work.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        EXPECT_EQ(SceneDemand(render, *loaded.scene), 0u)
            << "writing the caption it already had woke the scene up";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TextProducedByAScriptIsNeverCalledStill)
{
    // The limit of the change above, and the one it must not cross. A caption
    // whose value is computed every tick keeps the clock, whatever the script
    // happens to return: nothing here reads the script's body, counts repeated
    // results or infers when it will next differ.
    const auto project = WriteTextFixture(
        root_ / "scripted-text",
        "HELLO",
        false,
        R"({"value":"HELLO","script":"export function update(value) { return '12:34'; }"})");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "scripted-text-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        for (int frame = 0; frame < 30; ++frame) {
            AdvanceSceneFrame(render, *loaded.scene);
            ASSERT_TRUE(SceneDemand(render, *loaded.scene) &
                        wallpaper::SceneDemandReason::Script)
                << "a scripted caption was allowed to look like a still scene on frame " << frame;
        }

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TextBoundToAUserPropertyIsEventDrivenRatherThanContinuous)
{
    // A caption the user's own property supplies changes when they change it,
    // which is an event and not a timeline. The binding exists for the whole
    // life of the scene; that on its own must not keep the clock running.
    const auto project = WriteTextFixture(root_ / "property-text",
                                          "HELLO",
                                          false,
                                          R"({"value":"HELLO","user":"caption"})");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "property-text-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "a caption bound to a user property never stopped asking for frames";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AStaticTextLayerUnderAnEffectChainAlsoRunsOutOfWork)
{
    // The effect chain adds two more cards the relayout rewrites and two more
    // passes. None of them is driven by anything, so the scene is still still.
    const auto  project = WriteTextFixture(root_ / "effect-text-idle", "HELLO", true);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "effect-text-idle-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "a text layer under an effect chain never stopped asking for frames";
        EXPECT_GT(LitPixels(ReadOutput(render, *loaded.scene)), 0u)
            << "the chain went quiet without drawing anything";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AnOptionalProgramTranslatedOnceIsRestoredFromDiskOnTheNextLaunch)
{
    // What "persisted" has to mean, and the only way to show it without a
    // second process: the translation runs once, and a compile that starts from
    // an empty in-memory cache -- which is what a new launch is -- produces the
    // same Metal source, the same reflection and the same binding plan without
    // the compiler running at all.
    const auto project = WriteVideoFixture(root_ / "variant-cache-project", kVideoWidth,
                                           kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    const auto  cache_root = root_ / "variant-cache";
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, cache_root, loaded, error)) << error;

    auto* material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->hasVideoPlaneCandidate())
        << "no plane variant was possible, so there is nothing to persist";
    const auto& inputs = *program->video_plane_inputs;

    const auto compile = [&inputs, &cache_root](
                             std::vector<shader::RustShaderMetalStage>& stages,
                             std::string& reflection) {
        std::string failure;
        const bool  ok = WPShaderParser::CompileMslVariant(
            inputs, cache_root.string(), stages, &reflection, &failure);
        EXPECT_TRUE(ok) << failure;
        return ok;
    };

    // ---- first launch: nothing on disk for this program yet
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    std::vector<shader::RustShaderMetalStage> first;
    std::string                               first_reflection;
    ASSERT_TRUE(compile(first, first_reflection));
    const auto cold = WPShaderParser::GetStartupMetrics();
    ASSERT_EQ(cold.cache_hits, 0u) << "the first translation was already a hit";
    ASSERT_EQ(cold.cache_misses, 1u);
    ASSERT_FALSE(first.empty());
    ASSERT_FALSE(first_reflection.empty());

    // ---- next launch: the process remembers nothing, the disk does
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    std::vector<shader::RustShaderMetalStage> second;
    std::string                               second_reflection;
    ASSERT_TRUE(compile(second, second_reflection));
    const auto warm = WPShaderParser::GetStartupMetrics();
    EXPECT_EQ(warm.cache_misses, 0u)
        << "the optional program was translated again from source on a later launch";
    EXPECT_EQ(warm.cache_hits, 1u);

    // Restoring the Metal source alone would not be enough: without the
    // reflection and the per-stage binding plan the renderer cannot bind
    // anything to it, and would have to compile it again to find out.
    EXPECT_EQ(second_reflection, first_reflection);
    ASSERT_EQ(second.size(), first.size());
    for (std::size_t i = 0; i < first.size(); ++i) {
        EXPECT_EQ(second[i].source, first[i].source);
        EXPECT_EQ(second[i].entry_point, first[i].entry_point);
        EXPECT_EQ(second[i].language_version, first[i].language_version);
        ASSERT_EQ(second[i].bindings.size(), first[i].bindings.size())
            << "stage " << i << " came back with a different binding plan";
        for (std::size_t b = 0; b < first[i].bindings.size(); ++b) {
            EXPECT_EQ(second[i].bindings[b].name, first[i].bindings[b].name);
            EXPECT_EQ(second[i].bindings[b].slot, first[i].bindings[b].slot);
            EXPECT_EQ(second[i].bindings[b].slot_kind, first[i].bindings[b].slot_kind);
        }
    }

    // ---- a cache that is there but unreadable is not a failure
    //
    // Truncating every stored program is the worst case a partial write or a
    // half-deleted folder can produce. The wallpaper must still get its
    // variant; the cache is an optimisation and never a dependency.
    std::size_t corrupted = 0;
    for (const auto& entry :
         std::filesystem::directory_iterator(cache_root / "metal-draw-smoke" / "programs01")) {
        if (! entry.is_regular_file()) continue;
        std::ofstream(entry.path(), std::ios::trunc) << "{\"request\": ";
        ++corrupted;
    }
    ASSERT_GT(corrupted, 0u) << "nothing was written to disk, so nothing was persisted";

    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    std::vector<shader::RustShaderMetalStage> recovered;
    std::string                               recovered_reflection;
    ASSERT_TRUE(compile(recovered, recovered_reflection))
        << "a corrupted cache entry stopped the variant being produced";
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, 1u)
        << "a corrupted entry was read as a hit";
    ASSERT_EQ(recovered.size(), first.size());
    EXPECT_EQ(recovered.front().source, first.front().source);
    EXPECT_EQ(recovered_reflection, first_reflection);
}

TEST_F(MetalSceneDraw, PipelinesThisProcessBuildsAreArchivedAndServeTheProductionPath)
{
    // What the archive has to be able to say, and the only claim worth making
    // about it: the file this process writes is handed to the real pipeline
    // creation path -- the same `newRenderPipelineStateWithDescriptor:` a
    // wallpaper goes through -- and Metal can satisfy those descriptors from it
    // without compiling. The strict option is used only here, to tell an actual
    // hit apart from a fast recompile; the renderer never asks that way,
    // because a cold cache must never stop a wallpaper loading.
    const auto archive_root = root_ / "pipeline-archive";
    std::filesystem::create_directories(archive_root);

    const auto  project = WriteFixture(root_ / "archive-project", "0.375");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "archive-cache", loaded, error)) << error;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        // Per surface, as the scene's own command sets it: another display
        // showing a different wallpaper keeps its own store.
        render.SetPipelineArchivePath(archive_root.string());
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        AdvanceSceneFrame(render, *loaded.scene);

        // A first run has no file to read from, so nothing is attached to its
        // descriptors and everything is compiled -- which is the honest state
        // and not a failure. What it does is collect.
        EXPECT_GT(MetalPipelineArchiveStatusForDiagnostics().collected, 0u)
            << "the pipelines this scene needed were never offered to the archive";

        // Published, reopened from disk and asked strictly: this is the next
        // launch's question, answered without one.
        EXPECT_TRUE(MetalRender::PipelineArchiveServesEverySeenPipelineForTests())
            << "the archive could not supply a pipeline it had been given";

        const auto status = MetalPipelineArchiveStatusForDiagnostics();
        EXPECT_TRUE(status.available) << "the published archive could not be reopened";
        EXPECT_GT(status.published, 0u) << "the archive was never written out";

        render.destroy();
    }

    // Written to disk, under the regenerable cache and nowhere else.
    std::size_t files = 0;
    for (const auto& entry : std::filesystem::directory_iterator(archive_root)) {
        if (entry.is_regular_file() && entry.file_size() > 0) ++files;
    }
    EXPECT_GT(files, 0u) << "the archive was never published, so a later launch inherits nothing";

    // An unwritable or absent store is not a failure: pipelines are created
    // exactly as they were before any of this existed. This renderer is simply
    // never given a path.
    LoadedScene without;
    ASSERT_TRUE(LoadScene(WriteFixture(root_ / "no-archive-project", "0.4375"),
                          root_ / "no-archive-cache", without, error))
        << error;
    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*without.scene);
        ASSERT_NE(graph, nullptr);
        EXPECT_TRUE(render.compileRenderGraph(*without.scene, *graph)) << render.lastError();
        AdvanceSceneFrame(render, *without.scene);
        EXPECT_GT(LitPixels(ReadOutput(render, *without.scene)), 0u)
            << "a wallpaper stopped drawing when there was no pipeline archive";
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ACaptionChangedWhileHiddenIsNotWorkInFlight)
{
    // The trap in reporting "text is still being laid out" as a reason to keep
    // drawing: the pump skips hidden layers, so a caption changed while its
    // layer is hidden is pending and is not being worked on. Counting it would
    // leave the wallpaper drawing forever for work nobody is doing. Showing the
    // layer again is an event, and the layout happens then.
    const auto  project = WriteTextFixture(root_ / "hidden-text", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "hidden-text-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene));

        ASSERT_TRUE(loaded.scene->runtime->SetNodeVisible("caption", false));
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene, 60))
            << "a caption changed behind a hidden layer kept the scene drawing for work the "
               "text pump never starts";

        // And the work is not lost: showing the layer again produces it.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeVisible("caption", true));
        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "the deferred layout never finished after the layer came back";
        EXPECT_GT(LitPixels(ReadOutput(render, *loaded.scene)), 0u)
            << "the layer came back empty";

        render.destroy();
    }
}

// ---------------------------------------------------------------------------
// Skinning, rope and trail layouts on a real device

namespace
{

/// Same project as `WriteFixture`, with a named vertex shader of the caller's
/// choosing. The fragment is the probe that writes `(u, v, 0.25, 1)`.
std::filesystem::path WriteShaderFixture(const std::filesystem::path& root,
                                         std::string_view             shader_name,
                                         std::string_view             vertex_source)
{
    const std::string fragment =
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_FragColor = vec4(v_TexCoord.x, v_TexCoord.y, 0.25, 1.0);\n"
        "}\n";
    const std::string shader(shader_name);
    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal draw smoke","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        { "models/tile.json", R"({"width":256,"height":192,"material":"materials/tile.json"})" },
        { "materials/tile.json",
          "{\"passes\":[{\"shader\":\"" + shader +
              "\",\"blending\":\"translucent\",\"cullmode\":\"nocull\",\"depthtest\":\"disabled\","
              "\"depthwrite\":\"disabled\"}]}" },
        { "shaders/" + shader + ".vert", std::string(vertex_source) },
        { "shaders/" + shader + ".frag", fragment },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return root / "project.json";
}

bool PixelRectEqual(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, uint32_t width,
                    uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1)
{
    if (a.size() != b.size() || width == 0 || a.size() % (width * 4u) != 0) return false;
    const uint32_t height = static_cast<uint32_t>(a.size() / (width * 4u));
    if (x1 > width || y1 > height || x0 >= x1 || y0 >= y1) return false;
    for (uint32_t y = y0; y < y1; ++y) {
        for (uint32_t x = x0; x < x1; ++x) {
            const std::size_t i = (static_cast<std::size_t>(y) * width + x) * 4u;
            if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] ||
                a[i + 3] != b[i + 3]) {
                return false;
            }
        }
    }
    return true;
}

} // namespace

namespace
{

/// A two-bone puppet whose second bone slides 80 units along +X over a 0.3 s
/// loop while the first stays put, with one visible animation layer playing it.
WPPuppetLayer MakeSlidingPuppetLayer()
{
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.emplace_back().name = "root";
    puppet->bones.emplace_back().name = "shift";
    auto& anim                        = puppet->anims.emplace_back();
    anim.id                           = 1;
    anim.fps                          = 30.0;
    anim.length                       = 9;
    anim.mode                         = WPPuppet::PlayMode::Loop;
    anim.name                         = "slide";
    auto still_frame                  = []() {
        WPPuppet::BoneFrame frame;
        frame.position = Eigen::Vector3f::Zero();
        frame.angle    = Eigen::Vector3f::Zero();
        frame.scale    = Eigen::Vector3f::Ones();
        return frame;
    };
    // Sized first: a reference taken from `emplace_back` would dangle as soon as
    // the second track made the vector grow.
    anim.bone_tracks.resize(2);
    auto& track0        = anim.bone_tracks[0];
    track0.bone_index   = 0;
    auto& track1        = anim.bone_tracks[1];
    track1.bone_index   = 1;
    constexpr int kKeys = 10;
    for (int i = 0; i < kKeys; ++i) {
        track0.frames.push_back(still_frame());
        auto frame          = still_frame();
        frame.position.x()  = 80.0f * (static_cast<float>(i) / static_cast<float>(kKeys - 1));
        track1.frames.push_back(frame);
    }
    puppet->prepared();

    WPPuppetLayer                  layer(puppet);
    WPPuppetLayer::AnimationLayer  anim_layer;
    anim_layer.id      = 1;
    anim_layer.rate    = 1.0;
    anim_layer.blend   = 1.0;
    anim_layer.visible = true;
    layer.prepared(std::span<WPPuppetLayer::AnimationLayer>(&anim_layer, 1));

    return layer;
}

/// Two separate quads in the node's local space, the first bound wholly to
/// bone 0 and the second wholly to bone 1, in the vertex layout the model
/// parser gives a puppet mesh. The second quad's texture coordinate is (1, 1)
/// and the first's (0, 0), so the probe fragment shader colours them apart.
std::shared_ptr<SceneMesh> MakeTwoQuadSkinnedMesh(std::shared_ptr<SceneMaterial> material)
{
    auto mesh = std::make_shared<SceneMesh>();
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_BLENDINDICES), VertexType::UINT4 },
        { std::string(WE_IN_BLENDWEIGHTS), VertexType::FLOAT4 },
        { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 },
    };
    SceneVertexArray vertices(attributes, 8);
    auto pack = [](float x, float y, uint32_t bone, float u, float v) {
        std::array<float, 16> out {};
        out[0] = x;
        out[1] = y;
        // UINT4 lives in the float slots as the raw 32-bit indices, not as floats.
        const uint32_t indices[4] = { bone, 0, 0, 0 };
        std::memcpy(out.data() + 4, indices, sizeof(indices));
        out[8]  = 1.0f;
        out[12] = u;
        out[13] = v;
        return out;
    };
    const std::array<std::array<float, 16>, 8> packed {
        pack(-140.0f, -30.0f, 0, 0.0f, 0.0f), pack(-60.0f, -30.0f, 0, 0.0f, 0.0f),
        pack(-60.0f, 30.0f, 0, 0.0f, 0.0f),   pack(-140.0f, 30.0f, 0, 0.0f, 0.0f),
        pack(20.0f, -30.0f, 1, 1.0f, 1.0f),   pack(100.0f, -30.0f, 1, 1.0f, 1.0f),
        pack(100.0f, 30.0f, 1, 1.0f, 1.0f),   pack(20.0f, 30.0f, 1, 1.0f, 1.0f),
    };
    for (std::size_t i = 0; i < packed.size(); ++i) vertices.SetVertexs(i, packed[i]);
    mesh->AddVertexArray(std::move(vertices));
    const std::array<uint16_t, 12> triangles { 0, 1, 3, 1, 2, 3, 4, 5, 7, 5, 6, 7 };
    SceneIndexArray                index_array(4);
    index_array.AssignHalf(0, triangles);
    mesh->AddIndexArray(std::move(index_array));
    mesh->MaterialSlots().push_back(material);
    return mesh;
}

} // namespace

TEST_F(MetalSceneDraw, APuppetIsSkinnedByItsOwnShaderFromThePoseTheRuntimeProduces)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "uniform mat4x3 g_Bones[2];\n"
        "attribute vec3 a_Position;\n"
        "attribute uvec4 a_BlendIndices;\n"
        "attribute vec4 a_BlendWeights;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  vec3 localPos = mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x + "
        "g_Bones[a_BlendIndices.y] * a_BlendWeights.y + g_Bones[a_BlendIndices.z] * a_BlendWeights.z + "
        "g_Bones[a_BlendIndices.w] * a_BlendWeights.w);\n"
        "  gl_Position = mul(vec4(localPos, 1.0), g_ModelViewProjectionMatrix);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    const auto  project = WriteShaderFixture(root_ / "skin-project", "metal_skin_probe", vertex);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "skin-cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->error.empty()) << program->error;

    auto layer = MakeSlidingPuppetLayer();
    node->AddMesh(MakeTwoQuadSkinnedMesh(material));

    ASSERT_NE(loaded.scene->shaderValueUpdater.get(), nullptr);
    WPShaderValueData data;
    data.puppet_layer = layer;
    static_cast<WPShaderValueUpdater*>(loaded.scene->shaderValueUpdater.get())
        ->SetNodeData(node, data);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    MetalShaderReflection reflection;
    std::string           reflection_error;
    ASSERT_TRUE(ParseMetalShaderReflection(program->reflection_json, reflection, &reflection_error))
        << reflection_error;
    const auto* bones = reflection.member("g_Bones");
    ASSERT_NE(bones, nullptr) << "translated program has no g_Bones member";
    EXPECT_EQ(bones->array_count, 2u);
    EXPECT_EQ(bones->array_stride, 64u);

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        CAMetalLayer* layer_view  = [CAMetalLayer layer];
        layer_view.device          = device;
        layer_view.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer_view.drawableSize    = CGSizeMake(640, 360);
        layer_view.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer_view,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::BoneUniform)
            << "a skinned puppet was not reported as advancing on its own";

        const auto first = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(first.skipped, 0u);
        const auto first_pixels = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(first_pixels.empty());
        ASSERT_EQ(first_pixels.size() % 4u, 0u);
        const uint32_t canvas_w =
            first_pixels.size() == 640u * 360u * 4u ? 640u : 384u;
        const uint32_t canvas_h =
            static_cast<uint32_t>(first_pixels.size() / (canvas_w * 4u));
        // Bone 0 sits in the left-centre of the 384x256 canvas; mapped into the
        // output so a Y-flip still covers the same vertically centred band.
        const uint32_t x0 = canvas_w * 18u / 100u;
        const uint32_t x1 = canvas_w * 28u / 100u;
        const uint32_t y0 = canvas_h * 42u / 100u;
        const uint32_t y1 = canvas_h * 58u / 100u;

        std::vector<std::vector<uint8_t>> frames { first_pixels };
        loaded.scene->PassFrameTime(0.2);
        for (int frame = 0; frame < 3; ++frame) {
            const auto counters = DrawOneFrame(render, *loaded.scene);
            EXPECT_EQ(counters.skipped, 0u)
                << "a moving bone reused its target on frame " << frame;
            auto pixels = ReadOutput(render, *loaded.scene);
            EXPECT_NE(pixels, first_pixels)
                << "the skinned pose advanced and the picture did not change";
            frames.push_back(std::move(pixels));
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }

        // Not merely "different": the bone-1 quad must have TRANSLATED. Its
        // fragment colour is (1, 1, 0.25), so its columns can be told from the
        // bone-0 quad's and the background in either byte order. The pose at
        // 0.2 s of a 0.3 s slide over 80 units is two thirds of the quad's own
        // 80-unit width, whatever scale the output was composed at -- and a
        // transposed or re-ordered bone matrix shears or scales the quad
        // instead of moving it, which changes that width.
        const auto bright_columns = [canvas_w](const std::vector<uint8_t>& rgba) {
            std::pair<int, int> columns { -1, -1 };
            for (std::size_t pixel = 0; pixel * 4 + 3 < rgba.size(); ++pixel) {
                const uint8_t* p = rgba.data() + pixel * 4;
                if (p[1] < 200 || std::max(p[0], p[2]) < 200 || std::min(p[0], p[2]) > 120) continue;
                const int x = static_cast<int>(pixel % canvas_w);
                if (columns.first < 0 || x < columns.first) columns.first = x;
                if (x > columns.second) columns.second = x;
            }
            return columns;
        };
        const auto at_rest = bright_columns(frames[0]);
        const auto slid    = bright_columns(frames[1]);
        ASSERT_GE(at_rest.first, 0) << "the bone-1 quad was not found in the first frame";
        ASSERT_GE(slid.first, 0) << "the bone-1 quad was not found after the pose advanced";
        const double rest_width = at_rest.second - at_rest.first + 1;
        const double slid_width = slid.second - slid.first + 1;
        EXPECT_NEAR(slid_width, rest_width, 2.0)
            << "the skinned quad changed shape instead of moving";
        EXPECT_NEAR((slid.first - at_rest.first) / rest_width, 2.0 / 3.0, 0.05)
            << "the skinned quad did not move by the distance its bone did";

        layer.pause(0);
        loaded.scene->PassFrameTime(0.2);
        DrawOneFrame(render, *loaded.scene);
        const auto paused_a = ReadOutput(render, *loaded.scene);
        loaded.scene->PassFrameTime(0.2);
        DrawOneFrame(render, *loaded.scene);
        const auto paused_b = ReadOutput(render, *loaded.scene);
        EXPECT_EQ(paused_a, paused_b)
            << "a paused puppet still changed while time passed";
        frames.push_back(paused_a);

        layer.play(0);
        loaded.scene->PassFrameTime(0.2);
        const auto played = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(played.skipped, 0u);
        const auto played_pixels = ReadOutput(render, *loaded.scene);
        EXPECT_NE(played_pixels, paused_a)
            << "play() did not move the skinned picture again";
        frames.push_back(played_pixels);

        for (std::size_t i = 1; i < frames.size(); ++i) {
            EXPECT_TRUE(PixelRectEqual(frames[i], frames[0], canvas_w, x0, y0, x1, y1))
                << "the bone-0 quad moved on frame " << i;
        }

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ARopeLayoutMeshReachesTheTarget)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec4 a_PositionVec4;\n"
        "attribute vec4 a_TexCoordVec4;\n"
        "attribute vec4 a_TexCoordVec4C1;\n"
        "attribute vec3 a_TexCoordVec3C2;\n"
        "attribute vec2 a_TexCoordC3;\n"
        "attribute vec4 a_Color;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  vec3 position = mix(a_PositionVec4.xyz, a_TexCoordVec4.xyz, a_TexCoordC3.y) + "
        "vec3(0.0, (a_TexCoordC3.x * 2.0 - 1.0) * a_PositionVec4.w, 0.0);\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(position, 1.0);\n"
        "  v_TexCoord = a_TexCoordC3;\n"
        "}\n";
    const auto  project = WriteShaderFixture(root_ / "rope-project", "metal_rope_probe", vertex);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "rope-cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);

    auto dynamic_mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { WE_IN_POSITIONVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC3C2.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDC3.data(), VertexType::FLOAT4 },
        { WE_IN_COLOR.data(), VertexType::FLOAT4 },
    };
    constexpr std::size_t kQuads = 4;
    dynamic_mesh->AddVertexArray(SceneVertexArray(attributes, kQuads * 4));
    dynamic_mesh->AddIndexArray(SceneIndexArray(kQuads));
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_ROPE, true);
    dynamic_mesh->MaterialSlots().push_back(material);
    node->AddMesh(dynamic_mesh);

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto empty = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(empty.empty());

        auto& vertices = dynamic_mesh->GetVertexArray(0);
        auto& indices  = dynamic_mesh->GetIndexArray(0);
        const std::array<float, 2> uv[4] { { 0.0f, 1.0f }, { 1.0f, 1.0f }, { 1.0f, 0.0f }, { 0.0f, 0.0f } };
        std::array<float, 24 * 4>  segment {};
        for (int i = 0; i < 4; ++i) {
            float* v = segment.data() + i * 24;
            v[0]  = -150.0f;
            v[1]  = 0.0f;
            v[2]  = 0.0f;
            v[3]  = 20.0f;
            v[4]  = 150.0f;
            v[5]  = 0.0f;
            v[6]  = 0.0f;
            v[7]  = 1.0f;
            v[8]  = -150.0f;
            v[9]  = 0.0f;
            v[10] = 0.0f;
            v[11] = 0.0f;
            v[12] = 150.0f;
            v[13] = 0.0f;
            v[14] = 0.0f;
            v[15] = 0.0f;
            v[16] = uv[i][0];
            v[17] = uv[i][1];
            v[18] = 0.0f;
            v[19] = 0.0f;
            v[20] = 1.0f;
            v[21] = 1.0f;
            v[22] = 1.0f;
            v[23] = 1.0f;
        }
        vertices.SetVertexs(0, segment);
        const std::array<uint16_t, 6> quad_indices { 0, 1, 3, 1, 2, 3 };
        indices.AssignHalf(0, quad_indices);
        indices.SetRenderDataCount(3);
        dynamic_mesh->SetDirty();

        for (int frame = 0; frame < 5; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto filled = ReadOutput(render, *loaded.scene);
        EXPECT_NE(filled, empty)
            << "a rope layout uploaded after the graph was compiled never reached the target";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ASpriteTrailMeshReachesTheTarget)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec4 a_TexCoordVec4;\n"
        "attribute vec4 a_Color;\n"
        "attribute vec4 a_TexCoordVec4C1;\n"
        "attribute vec2 a_TexCoordC2;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  vec3 position = a_Position + vec3((a_TexCoordVec4.x - 0.5) * 2.0 * a_TexCoordVec4.w, "
        "(a_TexCoordVec4.y - 0.5) * 2.0 * a_TexCoordVec4.w, 0.0) + "
        "a_TexCoordVec4C1.xyz * a_TexCoordVec4.y;\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(position, 1.0);\n"
        "  v_TexCoord = a_TexCoordVec4.xy;\n"
        "}\n";
    const auto  project = WriteShaderFixture(root_ / "trail-project", "metal_trail_probe", vertex);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "trail-cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);

    auto dynamic_mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { WE_IN_POSITION.data(), VertexType::FLOAT3 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_COLOR.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDC2.data(), VertexType::FLOAT2 },
    };
    constexpr std::size_t kQuads = 4;
    dynamic_mesh->AddVertexArray(SceneVertexArray(attributes, kQuads * 4));
    dynamic_mesh->AddIndexArray(SceneIndexArray(kQuads));
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_SPRITE, true);
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_TRAIL, true);
    dynamic_mesh->GetVertexArray(0).SetOption(WE_CB_THICK_FORMAT, true);
    dynamic_mesh->MaterialSlots().push_back(material);
    node->AddMesh(dynamic_mesh);

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto empty = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(empty.empty());

        auto& vertices = dynamic_mesh->GetVertexArray(0);
        auto& indices  = dynamic_mesh->GetIndexArray(0);
        const std::array<float, 2> uv[4] { { 0.0f, 1.0f }, { 1.0f, 1.0f }, { 1.0f, 0.0f }, { 0.0f, 0.0f } };
        std::array<float, 20 * 4>  particle {};
        for (int i = 0; i < 4; ++i) {
            float* v = particle.data() + i * 20;
            v[0]  = 0.0f;
            v[1]  = 0.0f;
            v[2]  = 0.0f;
            v[4]  = uv[i][0];
            v[5]  = uv[i][1];
            v[6]  = 0.0f;
            v[7]  = 40.0f;
            v[8]  = 1.0f;
            v[9]  = 1.0f;
            v[10] = 1.0f;
            v[11] = 1.0f;
            v[12] = 80.0f;
            v[13] = 0.0f;
            v[14] = 0.0f;
            v[15] = 1.0f;
        }
        vertices.SetVertexs(0, particle);
        const std::array<uint16_t, 6> quad_indices { 0, 1, 3, 1, 2, 3 };
        indices.AssignHalf(0, quad_indices);
        indices.SetRenderDataCount(3);
        dynamic_mesh->SetDirty();

        for (int frame = 0; frame < 5; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto filled = ReadOutput(render, *loaded.scene);
        EXPECT_NE(filled, empty)
            << "a sprite-trail layout uploaded after the graph was compiled never reached the target";

        render.destroy();
    }
}

namespace
{

/// Wallpaper Engine's own shipped assets, where the editor's particle renderer
/// previews live. Resolved from the environment, never from a fixed home
/// directory; absent on a clean checkout, in which case the test below skips.
std::filesystem::path LocalSceneAssetsRoot()
{
    if (const char* assets = std::getenv("WE_TEST_ASSETS"); assets != nullptr && *assets != '\0') {
        return assets;
    }
    const char* home = std::getenv("HOME");
    if (home == nullptr || *home == '\0') return {};
    return std::filesystem::path(home) / "Library/Application Support/WallpaperMachine/SceneAssets";
}

std::size_t DifferingBytes(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b)
{
    if (a.size() != b.size()) return std::max(a.size(), b.size());
    std::size_t differing = 0;
    for (std::size_t i = 0; i < a.size(); ++i) differing += a[i] != b[i] ? 1u : 0u;
    return differing;
}

} // namespace

TEST_F(MetalSceneDraw, TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively)
{
    // The production path end to end, on content this repository does not own:
    // the real project file, the real particle definition, the author's own
    // `genericparticle` / `genericropeparticle` shaders through the structured
    // translation, the shared simulation, and this backend's dynamic upload.
    // What it proves is that each renderer is accepted and that simulated
    // geometry reaches the target. It does not judge how the result looks.
    const auto assets = LocalSceneAssetsRoot();
    const auto previews = assets / "scenes/particleelementpreviews";
    if (assets.empty() || ! std::filesystem::is_directory(previews)) {
        GTEST_SKIP() << "Wallpaper Engine's shipped assets are not installed here; the rope, rope "
                        "trail and sprite trail renderers were not exercised on real content";
    }

    for (const std::string name : { "spritetrail", "rope", "ropetrail" }) {
        SCOPED_TRACE(name);
        const auto directory = previews / name;
        const auto project   = directory / "project.json";
        if (! std::filesystem::is_regular_file(project)) {
            ADD_FAILURE() << "the shipped assets have no preview scene for this renderer";
            continue;
        }

        // The same variable the offscreen probe honours, so one seed makes the
        // two backends simulate the same particles and their frames comparable.
        if (const char* seed = std::getenv("WE_TEST_RANDOM_SEED")) {
            Random::seed(static_cast<uint32_t>(std::strtoul(seed, nullptr, 10)));
        }
        LoadedScene loaded;
        ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
        ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "scene"));
        ASSERT_TRUE(loaded.vfs.Mount(
            "/cache", fs::CreatePhysicalFs((root_ / ("cache-" + name)).string(), true), "cache"));
        InstallVirtualAssets(loaded.vfs);
        std::string error;
        ASSERT_TRUE(ParseProjectProperties(project.string(), &loaded.properties, &error)) << error;
        auto source = loaded.vfs.Open("/assets/scene.json");
        ASSERT_NE(source, nullptr);
        WPSceneParser parser;
        loaded.scene = parser.Parse(SceneParseRequest {
                                        .scene_id           = "metal-preview-" + name,
                                        .project_path       = project.string(),
                                        .project_properties = &loaded.properties,
                                    },
                                    source->ReadAllStr(), loaded.vfs, loaded.sound);
        ASSERT_NE(loaded.scene, nullptr);
        ASSERT_NE(loaded.scene->paritileSys, nullptr);
        ASSERT_TRUE(loaded.scene->paritileSys->HasEmitters())
            << "the preview scene's particle object did not load";

        const auto selection = SelectSceneBackend(*loaded.scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

        @autoreleasepool {
            id<MTLDevice> device       = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer        = [CAMetalLayer layer];
            layer.device               = device;
            layer.pixelFormat          = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize         = CGSizeMake(512, 512);
            layer.framebufferOnly      = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 512,
                .height               = 512,
                .render_width         = 512,
                .render_height        = 512,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

            // Before the first tick nothing has been emitted.
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            const auto empty = ReadOutput(render, *loaded.scene);
            ASSERT_FALSE(empty.empty());

            // The wallpaper's own frame order: simulate, tick, draw, pass time.
            for (int frame = 0; frame < 90; ++frame) {
                loaded.scene->paritileSys->Emitt();
                if (loaded.scene->runtime != nullptr) loaded.scene->runtime->Tick(1.0 / 60.0);
                ASSERT_TRUE(render.drawFrame(*loaded.scene)) << "frame " << frame << ": "
                                                             << render.lastError();
                loaded.scene->PassFrameTime(1.0 / 60.0);
            }
            const auto simulated = ReadOutput(render, *loaded.scene);
            EXPECT_GT(DifferingBytes(simulated, empty), 64u)
                << "a second and a half of simulation drew nothing through the native backend";

            // Opt-in, for looking at the result by hand: the same variable the
            // offscreen probe writes its frames under. Nothing is written
            // otherwise, and nothing here reads a display.
            if (const char* output = std::getenv("WE_TEST_OUTPUT");
                output != nullptr && *output != '\0' && simulated.size() % 4 == 0) {
                const std::size_t pixels = simulated.size() / 4;
                const std::size_t side   = static_cast<std::size_t>(std::sqrt(double(pixels)));
                if (side * side == pixels) {
                    std::filesystem::create_directories(output);
                    std::ofstream image(std::filesystem::path(output) / ("metal-" + name + ".ppm"),
                                        std::ios::binary);
                    image << "P6\n" << side << " " << side << "\n255\n";
                    for (std::size_t i = 0; i < pixels; ++i) {
                        image.write(reinterpret_cast<const char*>(simulated.data() + i * 4), 3);
                    }
                }
            }

            render.destroy();
        }
    }
}

TEST_F(MetalSceneDraw, TheShippedImageShaderSkinsAPuppetThroughTheNativeBackend)
{
    // The probe shader above proves the matrix convention; this proves the
    // author's own `genericimage2`, compiled with the two combos the model
    // parser gives a puppet, survives the structured translation with a bone
    // array the runtime can fill and bone-weight inputs the mesh can feed.
    const auto assets = LocalSceneAssetsRoot();
    if (assets.empty() || ! std::filesystem::is_regular_file(assets / "shaders/genericimage2.vert")) {
        GTEST_SKIP() << "Wallpaper Engine's shipped shaders are not installed here; the real "
                        "skinning shader was not translated";
    }

    const auto directory = root_ / "real-skin-project";
    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal puppet probe","type":"scene","file":"scene.json","general":{"properties":{}}})" },
        { "models/tile.json", R"({"width":256,"height":192,"material":"materials/skin.json"})" },
        { "materials/skin.json",
          R"({"passes":[{"shader":"genericimage2","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":["util/white"],)"
          R"("combos":{"SKINNING":1,"BONECOUNT":2}}]})" },
        { "scene.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = directory / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }

    LoadedScene loaded;
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "scene"));
    ASSERT_TRUE(loaded.vfs.Mount(
        "/cache", fs::CreatePhysicalFs((root_ / "real-skin-cache").string(), true), "cache"));
    InstallVirtualAssets(loaded.vfs);
    std::string error;
    const auto  project = directory / "project.json";
    ASSERT_TRUE(ParseProjectProperties(project.string(), &loaded.properties, &error)) << error;
    auto source = loaded.vfs.Open("/assets/scene.json");
    ASSERT_NE(source, nullptr);
    WPSceneParser parser;
    loaded.scene = parser.Parse(SceneParseRequest {
                                    .scene_id           = "metal-real-skin",
                                    .project_path       = project.string(),
                                    .project_properties = &loaded.properties,
                                },
                                source->ReadAllStr(), loaded.vfs, loaded.sound);
    ASSERT_NE(loaded.scene, nullptr);

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto material = node->Mesh()->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->ok()) << program->error;

    MetalShaderReflection reflection;
    std::string           reflection_error;
    ASSERT_TRUE(ParseMetalShaderReflection(program->reflection_json, reflection, &reflection_error))
        << reflection_error;
    const auto* bones = reflection.member("g_Bones");
    ASSERT_NE(bones, nullptr) << "the skinning combo did not reach the translated program";
    EXPECT_EQ(bones->array_count, 2u);
    EXPECT_EQ(bones->array_stride, 64u);

    auto layer = MakeSlidingPuppetLayer();
    node->AddMesh(MakeTwoQuadSkinnedMesh(material));
    WPShaderValueData data;
    data.puppet_layer = layer;
    static_cast<WPShaderValueUpdater*>(loaded.scene->shaderValueUpdater.get())
        ->SetNodeData(node, data);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device       = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer_view   = [CAMetalLayer layer];
        layer_view.device          = device;
        layer_view.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer_view.drawableSize    = CGSizeMake(640, 360);
        layer_view.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer_view,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
        const auto at_rest = ReadOutput(render, *loaded.scene);
        loaded.scene->PassFrameTime(0.2);
        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
        const auto slid = ReadOutput(render, *loaded.scene);
        EXPECT_NE(slid, at_rest) << "the author's skinning shader drew the same picture for two poses";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ARopeTrailPastTheOldSixteenBitIndexLimitStaysARopeTrail)
{
    // 5 000 particles x 10 segments x authored subdivision 3 is 150 000 quads,
    // past the old packed 16-bit cap of 16 384. It must remain a rope trail
    // with 32-bit indices, not a sprite trail and not a reduced subdivision.
    const auto assets  = LocalSceneAssetsRoot();
    const auto preview = assets / "scenes/particleelementpreviews/ropetrail";
    if (assets.empty() || ! std::filesystem::is_regular_file(preview / "project.json")) {
        GTEST_SKIP() << "Wallpaper Engine's shipped assets are not installed here; the rope trail "
                        "index-width path was not exercised";
    }

    const auto directory = root_ / "big-ropetrail";
    std::filesystem::create_directories(directory);
    std::filesystem::copy(preview, directory, std::filesystem::copy_options::recursive);
    const auto particle_path = directory / "particles/new_particle_system.json";
    nlohmann::json particle;
    {
        std::ifstream input(particle_path);
        ASSERT_TRUE(input.good());
        particle = nlohmann::json::parse(input);
    }
    particle["maxcount"] = 5000;
    std::ofstream(particle_path) << particle.dump();

    LoadedScene loaded;
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "scene"));
    ASSERT_TRUE(loaded.vfs.Mount(
        "/cache", fs::CreatePhysicalFs((root_ / "big-ropetrail-cache").string(), true), "cache"));
    InstallVirtualAssets(loaded.vfs);
    std::string error;
    const auto  project = directory / "project.json";
    ASSERT_TRUE(ParseProjectProperties(project.string(), &loaded.properties, &error)) << error;
    auto source = loaded.vfs.Open("/assets/scene.json");
    ASSERT_NE(source, nullptr);
    WPSceneParser parser;
    loaded.scene = parser.Parse(SceneParseRequest {
                                    .scene_id           = "metal-big-ropetrail",
                                    .project_path       = project.string(),
                                    .project_properties = &loaded.properties,
                                },
                                source->ReadAllStr(), loaded.vfs, loaded.sound);
    ASSERT_NE(loaded.scene, nullptr);
    ASSERT_TRUE(loaded.scene->paritileSys->HasEmitters())
        << "the rope trail past the old 16-bit cap was dropped";

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    ASSERT_GT(node->Mesh()->VertexCount(), 0u);
    const auto& vertices = node->Mesh()->GetVertexArray(0);
    EXPECT_TRUE(vertices.GetOption(WE_PRENDER_ROPE));
    EXPECT_TRUE(vertices.GetOption(WE_PRENDER_TRAIL));
    EXPECT_TRUE(vertices.GetOption(WE_PRENDER_ROPETRAIL));
    EXPECT_FALSE(vertices.GetOption(WE_PRENDER_SPRITE));
    ASSERT_GT(node->Mesh()->IndexCount(), 0u);
    const auto& indices = node->Mesh()->GetIndexArray(0);
    EXPECT_EQ(indices.Width(), SceneIndexWidth::UInt32);
    EXPECT_GT(indices.QuadCapacity(), kMaxPackedUInt16Quads);

    const auto selection = SelectSceneBackend(*loaded.scene);
    EXPECT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;
}

namespace
{

uint16_t PackageVersionOf(const std::string& path)
{
    std::ifstream file(path, std::ios::binary);
    uint32_t      length = 0;
    file.read(reinterpret_cast<char*>(&length), sizeof(length));
    if (! file || length < 5 || length > 64) return SceneParseRequest::kUnknownPkgVersion;
    std::string stamp(length, '\0');
    file.read(stamp.data(), length);
    if (! file || ! stamp.starts_with("PKGV")) return SceneParseRequest::kUnknownPkgVersion;
    uint16_t version       = 0;
    const auto [end, code] = std::from_chars(stamp.data() + 4, stamp.data() + stamp.size(), version);
    return code == std::errc {} && end == stamp.data() + stamp.size()
               ? version
               : SceneParseRequest::kUnknownPkgVersion;
}

} // namespace

namespace {
/// Feeds the scene the now-playing state the app would deliver, with the same
/// two variables `offscreen_scene_probe` takes and the same meaning.
///
/// A wallpaper whose background is drawn from the current cover renders as flat
/// grey without one, so the two backends cannot be compared on the thing that
/// actually differs unless both can be given the same cover.
void InjectSystemMediaForMetal(Scene& scene) {
    const char* events  = std::getenv("WE_TEST_MEDIA_EVENTS");
    const char* artwork = std::getenv("WE_TEST_MEDIA_ARTWORK");
    if (events == nullptr && artwork == nullptr) return;
    if (scene.runtime == nullptr) return;
    scene.runtime->SetMediaIntegrationEnabled(true);

    if (artwork != nullptr) {
        unsigned width = 0, height = 0, rgb = 0;
        if (std::sscanf(artwork, "%ux%u:%x", &width, &height, &rgb) == 3 && width >= 1 &&
            width <= 4096 && height >= 1 && height <= 4096) {
            auto* images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
            // Said out loud rather than skipped quietly: a run that could not
            // publish the cover renders the same flat grey as a backend that
            // dropped it, and reading that as a backend defect is a mistake
            // this harness has already caused once.
            std::cout << "[ MEDIA    ] cover published: "
                      << (images != nullptr ? "yes" : "NO -- no runtime image source")
                      << std::endl;
            if (images != nullptr) {
                std::vector<uint8_t> rgba(std::size_t(width) * height * 4);
                for (std::size_t i = 0; i < rgba.size(); i += 4) {
                    rgba[i + 0] = uint8_t((rgb >> 16) & 0xFF);
                    rgba[i + 1] = uint8_t((rgb >> 8) & 0xFF);
                    rgba[i + 2] = uint8_t(rgb & 0xFF);
                    rgba[i + 3] = 0xFF;
                }
                PublishSystemMediaArtwork(*images, width, height, rgba.data(), rgba.size());
            }
        }
    }

    if (events != nullptr) {
        const auto parsed = nlohmann::json::parse(events, nullptr, false);
        if (!parsed.is_discarded() && parsed.is_array()) {
            for (const auto& event : parsed) {
                if (event.is_object()) scene.runtime->DispatchMediaEventJson(event.dump());
            }
            scene.runtime->Tick(1.0 / 60.0);
        }
    }
}
} // namespace

TEST_F(MetalSceneDraw, LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend)
{
    // For content this repository cannot carry -- a real puppet most of all.
    // `WE_TEST_METAL_PROJECTS` is a colon-separated list of `project.json`
    // paths; each is parsed exactly as the wallpaper loads it and its backend
    // decision is printed. A scene that falls back is reported with its reason
    // and is not a failure here: what must hold is that an ACCEPTED scene
    // prepares and draws every frame, because an accepted scene has no other
    // renderer behind it. `WE_TEST_PROPERTIES` and `WE_TEST_AUDIO_HZ` mean what
    // they mean for `offscreen_scene_probe`: a wallpaper whose layer is gated
    // on a saved property, or whose shader reads the spectrum, draws nothing
    // worth comparing without them, and this backend had no way to supply
    // either.
    const char* listed = std::getenv("WE_TEST_METAL_PROJECTS");
    const auto  assets = LocalSceneAssetsRoot();
    if (listed == nullptr || *listed == '\0' || assets.empty() ||
        ! std::filesystem::is_directory(assets)) {
        GTEST_SKIP() << "WE_TEST_METAL_PROJECTS names no local project; no real wallpaper was "
                        "drawn natively";
    }

    std::vector<std::string> projects;
    for (std::string_view rest = listed; ! rest.empty();) {
        const auto colon = rest.find(':');
        if (colon != 0) projects.emplace_back(rest.substr(0, colon));
        if (colon == std::string_view::npos) break;
        rest.remove_prefix(colon + 1);
    }

    // Reusing a completed result is a correctness claim about the passes it
    // skips. Turning it off is how a scene that looks wrong under it can be
    // compared with the same scene drawn every frame. Process-global, so it is
    // set once around the whole loop and put back: an unfiltered run must not
    // carry this choice into any later test.
    const bool optimization_was = wallpaper::vulkan::SceneOptimizationEnabled();
    if (const char* opt = std::getenv("WE_TEST_SCENE_OPTIMIZATION")) {
        wallpaper::vulkan::SetSceneOptimizationEnabled(std::string_view(opt) != "0");
    }

    std::size_t index = 0;
    for (const auto& project : projects) {
        SCOPED_TRACE(project);
        const std::string label = "local-" + std::to_string(index++);

        SceneSourcePaths paths;
        std::string      error;
        ASSERT_TRUE(ResolveSceneSourcePaths(project, &paths, &error)) << error;

        LoadedScene loaded;
        ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
        if (std::filesystem::exists(paths.pkg_path)) {
            ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs(paths.pkg_path)));
        } else {
            ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(paths.pkg_dir)));
        }
        ASSERT_TRUE(loaded.vfs.Mount(
            "/cache", fs::CreatePhysicalFs((root_ / ("cache-" + label)).string(), true), "cache"));
        InstallVirtualAssets(loaded.vfs);
        ASSERT_TRUE(ParseProjectProperties(project, &loaded.properties, &error)) << error;
        if (const char* json = std::getenv("WE_TEST_PROPERTIES")) {
            ProjectProperties overrides;
            ASSERT_TRUE(ParseFlatProjectPropertyOverrideJson(json, &overrides, &error)) << error;
            loaded.properties = MergeProjectProperties(loaded.properties, overrides);
        }
        auto source = loaded.vfs.Open("/assets/" + paths.pkg_entry);
        ASSERT_NE(source, nullptr);
        WPSceneParser parser;
        loaded.scene = parser.Parse(SceneParseRequest {
                                        .scene_id           = paths.scene_id,
                                        .project_path       = project,
                                        .project_properties = &loaded.properties,
                                        .pkg_version        = PackageVersionOf(paths.pkg_path),
                                    },
                                    source->ReadAllStr(), loaded.vfs, loaded.sound);
        ASSERT_NE(loaded.scene, nullptr);

        InjectSystemMediaForMetal(*loaded.scene);
        const auto selection = SelectSceneBackend(*loaded.scene);
        if (selection.backend != SceneBackend::NativeMetal) {
            std::cout << "[ LOCAL    ] " << paths.scene_id << ": Compatibility -- "
                      << selection.fallback_reason << std::endl;
            continue;
        }

        // A real surface is the size of the display it is on, and screen-space
        // shader inputs -- texel size above all -- follow it. Comparing this
        // backend's output with another's is only meaningful when both
        // rasterize the same extent, so the size is overridable.
        uint32_t surface_width  = 960;
        uint32_t surface_height = 540;
        if (const char* size = std::getenv("WE_TEST_METAL_SURFACE")) {
            unsigned w = 0, h = 0;
            if (std::sscanf(size, "%ux%u", &w, &h) == 2 && w > 0 && h > 0) {
                surface_width  = w;
                surface_height = h;
            }
        }
        @autoreleasepool {
            id<MTLDevice> device       = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer        = [CAMetalLayer layer];
            layer.device               = device;
            layer.pixelFormat          = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize         = CGSizeMake(surface_width, surface_height);
            layer.framebufferOnly      = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = static_cast<uint16_t>(surface_width),
                .height               = static_cast<uint16_t>(surface_height),
                .render_width         = static_cast<uint16_t>(surface_width),
                .render_height        = static_cast<uint16_t>(surface_height),
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            if (! render.compileRenderGraph(*loaded.scene, *graph)) {
                // The production router treats this as a fallback too, with
                // this text as the reason.
                std::cout << "[ LOCAL    ] " << paths.scene_id
                          << ": Compatibility after prepare -- " << render.lastError() << std::endl;
                render.destroy();
                continue;
            }
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTCROP);

            const char* audio_hz = std::getenv("WE_TEST_AUDIO_HZ");
            if (audio_hz != nullptr && loaded.scene->runtime != nullptr) {
                loaded.scene->runtime->SetAudioResponseEnabled(true);
            }
            std::vector<uint8_t> first;
            for (int frame = 0; frame < 120; ++frame) {
                if (audio_hz != nullptr) {
                    // Synthetic PCM only, analysed by the same service the
                    // desktop tap feeds.
                    std::array<float, 2400> pcm {};
                    const double hz = std::strtod(audio_hz, nullptr);
                    for (std::size_t i = 0; i < pcm.size(); ++i) {
                        pcm[i] = 0.025f *
                                 std::sin(2.0 * M_PI * hz * double(i) / 12000.0);
                    }
                    const auto generation = audio::CurrentAudioSpectrumSnapshot().generation;
                    std::string audio_error;
                    ASSERT_TRUE(audio::SubmitMonoAudioFrames(
                        12000, uint32_t(pcm.size()), pcm.data(), &audio_error))
                        << audio_error;
                    const auto deadline =
                        std::chrono::steady_clock::now() + std::chrono::seconds(2);
                    while (audio::CurrentAudioSpectrumSnapshot().generation <= generation &&
                           std::chrono::steady_clock::now() < deadline) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                }
                loaded.scene->paritileSys->Emitt();
                if (loaded.scene->runtime != nullptr) {
                    loaded.scene->runtime->Tick(1.0 / 60.0);
                    loaded.scene->runtime->PumpTextLayerCache();
                }
                ASSERT_TRUE(render.drawFrame(*loaded.scene))
                    << "frame " << frame << ": " << render.lastError();
                if (frame == 0) first = ReadOutput(render, *loaded.scene);
                loaded.scene->PassFrameTime(1.0 / 60.0);
            }
            const auto last = ReadOutput(render, *loaded.scene);
            std::cout << "[ LOCAL    ] " << paths.scene_id << ": Native Metal, 120 frames drawn, "
                      << DifferingBytes(first, last) << " bytes differ between the first and the last"
                      << std::endl;

            if (const char* output = std::getenv("WE_TEST_OUTPUT");
                output != nullptr && *output != '\0' && ! last.empty()) {
                uint32_t width  = 0;
                uint32_t height = 0;
                std::vector<uint8_t> rgba;
                if (render.ReadRenderTargetForTests(loaded.scene->ResolveRenderTargetName(SpecTex_Default),
                                                    rgba, width, height) &&
                    width > 0 && height > 0) {
                    std::filesystem::create_directories(output);
                    std::ofstream image(std::filesystem::path(output) / ("metal-" + label + ".ppm"),
                                        std::ios::binary);
                    image << "P6\n" << width << " " << height << "\n255\n";
                    for (std::size_t i = 0; i < std::size_t(width) * height; ++i) {
                        image.write(reinterpret_cast<const char*>(rgba.data() + i * 4), 3);
                    }
                }
            }

            // Named intermediates, not just the final image. When this backend
            // and another disagree about a scene, the question is which pass
            // first diverges, and that is answered by holding the same target
            // from both against each other rather than by reading code.
            if (const char* wanted = std::getenv("WE_TEST_METAL_DUMP_TARGETS");
                wanted != nullptr && *wanted != '\0') {
                const char* output = std::getenv("WE_TEST_OUTPUT");
                // Target names carry a per-run suffix derived from the object
                // that owns them, so naming one across two processes is not
                // possible. `*` asks for every target the scene declares, which
                // is the same set on either backend.
                std::vector<std::string> keys;
                if (std::string_view(wanted) == "*") {
                    for (const auto& [name, target] : loaded.scene->renderTargets) {
                        (void)target;
                        keys.push_back(name);
                    }
                    std::sort(keys.begin(), keys.end());
                } else {
                    for (std::string_view rest = wanted; ! rest.empty();) {
                        const auto colon = rest.find(':');
                        if (colon != 0) keys.emplace_back(rest.substr(0, colon));
                        if (colon == std::string_view::npos) break;
                        rest.remove_prefix(colon + 1);
                    }
                }
                for (const auto& key : keys) {
                    uint32_t             width = 0, height = 0;
                    std::vector<uint8_t> rgba;
                    if (! render.ReadRenderTargetForTests(loaded.scene->ResolveRenderTargetName(key),
                                                          rgba, width, height) ||
                        width == 0 || height == 0) {
                        std::cout << "[ LOCAL    ] " << paths.scene_id << ": no target named " << key
                                  << std::endl;
                        continue;
                    }
                    double sum = 0.0;
                    for (std::size_t i = 0; i < std::size_t(width) * height; ++i) {
                        sum += (rgba[i * 4] + rgba[i * 4 + 1] + rgba[i * 4 + 2]) / 3.0;
                    }
                    std::cout << "[ LOCAL    ] " << paths.scene_id << ": " << key << " " << width << "x"
                              << height << " mean luma "
                              << sum / (double(width) * double(height)) << std::endl;
                    if (output == nullptr || *output == '\0') continue;
                    std::filesystem::create_directories(output);
                    std::string safe = key;
                    std::replace(safe.begin(), safe.end(), '/', '_');
                    std::ofstream image(std::filesystem::path(output) / ("metal-" + label + "-" + safe + ".ppm"),
                                        std::ios::binary);
                    image << "P6\n" << width << " " << height << "\n255\n";
                    for (std::size_t i = 0; i < std::size_t(width) * height; ++i) {
                        image.write(reinterpret_cast<const char*>(rgba.data() + i * 4), 3);
                    }
                    // Alpha on its own. Effects that weight by coverage -- the
                    // bokeh downsample divides by the sum of its taps' alpha --
                    // make completely different colour from the same RGB when
                    // alpha differs, so a colour-only dump cannot explain them.
                    if (std::getenv("WE_TEST_DUMP_ALPHA") != nullptr) {
                        std::ofstream alpha(std::filesystem::path(output) /
                                                ("metal-" + label + "-" + safe + "-alpha.ppm"),
                                            std::ios::binary);
                        alpha << "P6\n" << width << " " << height << "\n255\n";
                        for (std::size_t i = 0; i < std::size_t(width) * height; ++i) {
                            const char grey[3] { static_cast<char>(rgba[i * 4 + 3]),
                                                 static_cast<char>(rgba[i * 4 + 3]),
                                                 static_cast<char>(rgba[i * 4 + 3]) };
                            alpha.write(grey, 3);
                        }
                    }
                }
            }
            render.destroy();
        }
    }
    wallpaper::vulkan::SetSceneOptimizationEnabled(optimization_was);
}
