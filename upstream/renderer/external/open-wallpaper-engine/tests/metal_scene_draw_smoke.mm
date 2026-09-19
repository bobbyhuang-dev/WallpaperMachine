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
#include "WPSceneParser.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <gtest/gtest.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

using namespace wallpaper;
using namespace wallpaper::metal;

namespace
{

/// A minimal original scene: one flat-coloured card drawn through the author's
/// own vertex and fragment shaders. Small on purpose -- the point is that the
/// shader is real and travels the whole pipeline, not that the scene is rich.
std::filesystem::path WriteFixture(const std::filesystem::path& root)
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
        "  gl_FragColor = vec4(v_TexCoord.x, v_TexCoord.y, 0.25, 1.0);\n"
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
