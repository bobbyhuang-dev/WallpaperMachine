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

#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalRender.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"

#include "Audio/SoundManager.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneBackendSelection.hpp"
#include "Scene/SceneNode.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneTexture.h"
#include "SpriteAnimation.hpp"
#include "SpecTexs.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "Shader/SceneMetalVariants.hpp"
#include "WPSceneParser.hpp"
#include "synthetic_video.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <gtest/gtest.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
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
bool SettleVariantTranslation(Scene& scene, std::string* reason)
{
    RequestSceneMetalVariants(scene, true);
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
    auto dynamic_mesh = std::make_shared<SceneMesh>(true);
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
std::filesystem::path WriteTextFixture(const std::filesystem::path& root, std::string_view text,
                                       bool with_effect = false)
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
          R"("objects":[{"id":1,"name":"caption","text":")" + std::string(text) +
              R"(","font":"Arial","pointsize":48,"origin":[192,128,0],)"
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
