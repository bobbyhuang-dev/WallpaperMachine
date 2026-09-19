/// Native Metal backend: the capability gate, the blend mapping, the
/// clip-space derivation and the pipeline cache key.
///
/// Everything here is decided without a GPU on purpose -- these are the
/// decisions that must be right before a device is ever touched. The one test
/// that needs a Metal device says so and skips visibly when there is none.

#include "MetalRender/MetalBlend.hpp"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalProjection.hpp"
#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/SceneMetalProgram.hpp"
#include "MetalRender/ScenePassDescription.hpp"

#include "Particle/ParticleSystem.h"
#include "Presentation/WallpaperScaling.hpp"
#include "RenderGraph/PassNode.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Utils/Eigen.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <memory>
#include <string>

#ifdef __APPLE__
#include "MetalRender/MetalRender.hpp"
#endif

using namespace wallpaper;
using namespace wallpaper::metal;

namespace
{

constexpr std::string_view kReflectionJson = R"({
  "descriptor_bindings": [
    { "name": "Globals", "set": 0, "binding": 0, "descriptor": "uniform_buffer",
      "stages": ["vertex", "fragment"] },
    { "name": "g_Texture0", "set": 0, "binding": 1, "descriptor": "sampled_image",
      "stages": ["fragment"] },
    { "name": "_we_Sampler_g_Texture0", "set": 0, "binding": 2, "descriptor": "sampler",
      "stages": ["fragment"] }
  ],
  "uniform_blocks": [
    { "name": "Globals", "binding": 0, "size": 128, "members": [
      { "name": "g_ModelViewProjectionMatrix", "offset": 0, "size": 64 },
      { "name": "g_Alpha", "offset": 64, "size": 4 }
    ] }
  ],
  "vertex_inputs": [
    { "name": "a_Position", "location": 0, "format": "r32g32b32_sfloat" },
    { "name": "a_TexCoord", "location": 1, "format": "r32g32_sfloat" }
  ],
  "active_texture_slots": [0]
})";

/// Reflection for a shader driven by a puppet skeleton.
constexpr std::string_view kBonesReflectionJson = R"({
  "descriptor_bindings": [
    { "name": "Globals", "set": 0, "binding": 0, "descriptor": "uniform_buffer",
      "stages": ["vertex"] }
  ],
  "uniform_blocks": [
    { "name": "Globals", "binding": 0, "size": 256, "members": [
      { "name": "g_Bones", "offset": 0, "size": 48, "array_count": 4, "array_stride": 48 }
    ] }
  ],
  "vertex_inputs": [],
  "active_texture_slots": []
})";

std::shared_ptr<SceneMetalProgram> TranslatedProgram(std::string_view reflection = kReflectionJson)
{
    auto program             = std::make_shared<SceneMetalProgram>();
    program->reflection_json = std::string(reflection);
    program->stages.push_back(SceneMetalStage {
        .kind             = SceneMetalStageKind::Vertex,
        .source           = "vertex void main_() {}",
        .entry_point      = "main_",
        .language_version = "2.0",
        .bindings         = { SceneMetalBinding { "Globals", 0, 0, SceneMetalSlotKind::Buffer, 0 } },
    });
    program->stages.push_back(SceneMetalStage {
        .kind             = SceneMetalStageKind::Fragment,
        .source           = "fragment void main_() {}",
        .entry_point      = "main_",
        .language_version = "2.0",
        .bindings =
            {
                SceneMetalBinding { "Globals", 0, 0, SceneMetalSlotKind::Buffer, 0 },
                SceneMetalBinding { "g_Texture0", 0, 1, SceneMetalSlotKind::Texture, 1 },
                SceneMetalBinding { "_we_Sampler_g_Texture0", 0, 2, SceneMetalSlotKind::Sampler,
                                    2 },
            },
    });
    return program;
}

std::shared_ptr<SceneMetalProgram> FailedProgram()
{
    auto program   = std::make_shared<SceneMetalProgram>();
    program->error = "naga msl write failed";
    return program;
}

/// A minimal but complete two-dimensional image scene: one ortho camera, one
/// node, one card mesh, one material with a translated shader and one image.
struct ImageScene
{
    Scene                         scene;
    std::shared_ptr<SceneCamera>  global;
    std::shared_ptr<SceneCamera>  global_perspective;
    std::shared_ptr<SceneNode>    node;
    std::shared_ptr<SceneMesh>    mesh;

    ImageScene()
    {
        scene.scene_id = "metal-test-scene";
        global         = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
        global_perspective = std::make_shared<SceneCamera>(16.0f / 9.0f, 0.01f, 1000.0f, 50.0f);
        scene.cameras["global"]             = global;
        scene.cameras["global_perspective"] = global_perspective;
        scene.activeCamera                  = global.get();

        scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
            .width  = 1920,
            .height = 1080,
        };
        scene.textures["materials/card.tex"] = SceneTexture { .url = "materials/card.tex" };

        SceneMaterial material;
        material.name     = "materials/card";
        material.textures = { "materials/card.tex" };
        material.blenmode = BlendMode::Translucent;
        material.customShader.shader                 = std::make_shared<SceneShader>();
        material.customShader.shader->name           = "genericimage2";
        material.customShader.shader->metal_program  = TranslatedProgram();

        mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(std::move(material));
        node = std::make_shared<SceneNode>();
        node->AddMesh(mesh);
        scene.sceneGraph->AppendChild(node);
    }

    SceneMaterial& material() { return *mesh->MaterialSlots().front(); }
};

std::string RejectionFor(ImageScene& fixture)
{
    return EvaluateMetalSupport(fixture.scene).fallback_reason;
}

} // namespace

// ---------------------------------------------------------------------------
// Capability gate

TEST(MetalCapability, AcceptsAMinimalTwoDimensionalImageScene)
{
    ImageScene fixture;
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;
    EXPECT_TRUE(selection.fallback_reason.empty());
    EXPECT_FALSE(selection.fell_back());
}

TEST(MetalCapability, EveryUnsupportedConstructHasItsOwnReason)
{
    std::vector<std::pair<std::string, std::string>> reasons;

    {
        ImageScene fixture;
        fixture.scene.paritileSys->subsystems.push_back(nullptr);
        reasons.emplace_back("particles", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.scene.lights.push_back(
            std::make_unique<SceneLight>(Eigen::Vector3f { 1.0f, 1.0f, 1.0f }, 100.0f, 1.0f));
        reasons.emplace_back("lights", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.scene.post_processes.push_back(std::make_shared<ScenePostProcess>());
        reasons.emplace_back("post-process", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.scene.textures["video.mp4"] = SceneTexture { .url = "video.mp4", .isVideo = true };
        reasons.emplace_back("video", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.scene.textures["sheet.tex"] = SceneTexture { .url    = "sheet.tex",
                                                             .isSprite = true };
        reasons.emplace_back("sprite", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.scene.activeCamera = fixture.global_perspective.get();
        reasons.emplace_back("perspective", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.global->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
            fixture.node.get(), 1920.0f, 1080.0f, "_rt_effect_pingpong_a_0",
            "_rt_effect_pingpong_b_0"));
        reasons.emplace_back("image effect", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        // A material that samples the image it draws into is feedback.
        fixture.material().textures = { std::string(SpecTex_Default) };
        reasons.emplace_back("feedback", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.material().customShader.shader->metal_program = FailedProgram();
        reasons.emplace_back("untranslatable shader", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.material().customShader.shader->metal_program =
            TranslatedProgram(kBonesReflectionJson);
        reasons.emplace_back("puppet", RejectionFor(fixture));
    }
    {
        // Never translated, because the preference was off when the scene was
        // parsed. That is not a fault in the author's shader and must not be
        // reported as one.
        ImageScene fixture;
        fixture.material().customShader.shader->metal_program = nullptr;
        reasons.emplace_back("never attempted", RejectionFor(fixture));
    }

    for (const auto& [construct, reason] : reasons) {
        EXPECT_FALSE(reason.empty()) << construct << " was accepted";
    }
    for (std::size_t i = 0; i < reasons.size(); ++i) {
        for (std::size_t j = i + 1; j < reasons.size(); ++j) {
            EXPECT_NE(reasons[i].second, reasons[j].second)
                << reasons[i].first << " and " << reasons[j].first << " share a reason";
        }
    }

    // The two that are most easily confused, spelled out.
    const auto untranslatable =
        std::find_if(reasons.begin(), reasons.end(),
                     [](const auto& entry) { return entry.first == "untranslatable shader"; });
    const auto never_attempted =
        std::find_if(reasons.begin(), reasons.end(),
                     [](const auto& entry) { return entry.first == "never attempted"; });
    ASSERT_NE(untranslatable, reasons.end());
    ASSERT_NE(never_attempted, reasons.end());
    EXPECT_NE(untranslatable->second, never_attempted->second);
}

TEST(MetalCapability, RecognisedPassKindsAreClassifiedAndAnythingElseFallsBack)
{
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::CustomShader)),
              MetalPassKind::CustomShader);
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::Copy)),
              MetalPassKind::Copy);
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::Clear)),
              MetalPassKind::Clear);
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::Virtual)),
              MetalPassKind::Virtual);

    // A pass kind added after this build. It has to fall back, not be skipped
    // and not be drawn as something it resembles.
    const int unknown_kind = static_cast<int>(rg::PassNode::Type::Virtual) + 1;
    EXPECT_EQ(ClassifyMetalPassKind(unknown_kind), MetalPassKind::Unsupported);
    EXPECT_EQ(ClassifyMetalPassKind(-1), MetalPassKind::Unsupported);
}

// ---------------------------------------------------------------------------
// Blend mapping

TEST(MetalBlend, EachModeProducesTheAuthoredFactors)
{
    {
        const auto state = ToMetalBlendState(BlendMode::Disable);
        EXPECT_FALSE(state.blending_enabled);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        // An opaque replace. Not Porter-Duff source-over, despite the name:
        // source-over here would composite every "normal" layer wrongly.
        const auto state = ToMetalBlendState(BlendMode::Normal);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::One);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::Zero);
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::One);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::Zero);
        EXPECT_NE(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_NE(state.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        const auto state = ToMetalBlendState(BlendMode::Translucent);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
        // Coverage is As + Ad(1 - As), so the source alpha factor is ONE.
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::One);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        const auto state = ToMetalBlendState(BlendMode::Additive);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::One);
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::One);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        const auto state = ToMetalBlendState(BlendMode::AlphaToCoverage);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_TRUE(state.alpha_to_coverage);
    }

    for (const auto mode : { BlendMode::Disable, BlendMode::Normal, BlendMode::Translucent,
                             BlendMode::Additive, BlendMode::AlphaToCoverage }) {
        const auto state = ToMetalBlendState(mode);
        EXPECT_EQ(state.rgb_operation, MetalBlendOperation::Add);
        EXPECT_EQ(state.alpha_operation, MetalBlendOperation::Add);
    }
}

TEST(MetalBlend, SceneDrawsAreRasterizedWithoutCulling)
{
    // The compatibility backend rasterizes with VK_CULL_MODE_NONE, and any
    // clip-space fold reverses triangle winding. Culling here would either
    // disagree with the other backend or silently eat half a scene.
    EXPECT_EQ(kSceneCullMode, MetalCullMode::None);
}

// ---------------------------------------------------------------------------
// Pipeline cache keys

TEST(MetalPipelineKey, DistinguishesBlendModesAndTargetFormats)
{
    MetalPipelineKey base {
        .program_id       = 0x1234,
        .vertex_layout_id = 0x5678,
        .blend            = ToMetalBlendState(BlendMode::Translucent),
        .color_format     = MetalPixelFormat::RGBA8Unorm,
        .sample_count     = 1,
        .write_alpha      = true,
    };

    auto additive  = base;
    additive.blend = ToMetalBlendState(BlendMode::Additive);
    auto normal    = base;
    normal.blend   = ToMetalBlendState(BlendMode::Normal);
    auto bgra         = base;
    bgra.color_format = MetalPixelFormat::BGRA8Unorm;
    auto srgb         = base;
    srgb.color_format = MetalPixelFormat::RGBA8Unorm_sRGB;
    auto opaque        = base;
    opaque.write_alpha = false;

    const MetalPipelineKeyHash hash;
    for (const auto& other : { additive, normal, bgra, srgb, opaque }) {
        EXPECT_FALSE(base == other);
        EXPECT_NE(hash(base), hash(other));
    }

    auto same = base;
    EXPECT_TRUE(base == same);
    EXPECT_EQ(hash(base), hash(same));
}

// ---------------------------------------------------------------------------
// Clip space

TEST(MetalProjection, LandsAuthorGeometryOnTheSameWindowPixelAsTheCompatibilityBackend)
{
    // The presentation viewport the compatibility backend builds: a letterboxed
    // region written with a negative height, which is how Vulkan is made to
    // agree with the coordinate system the authored shaders use.
    const auto layout = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000,
                                                      1000, 1.0, 1.0);
    const VulkanViewportBox vulkan_viewport {
        .x      = static_cast<double>(layout.viewport_px.x),
        .y      = static_cast<double>(layout.viewport_px.y + layout.viewport_px.height),
        .width  = static_cast<double>(layout.viewport_px.width),
        .height = -static_cast<double>(layout.viewport_px.height),
    };
    ASSERT_LT(vulkan_viewport.height, 0.0) << "the compatibility viewport must be the flipped one";
    const auto metal_viewport = ToMetalViewport(vulkan_viewport);
    EXPECT_GT(metal_viewport.height, 0.0) << "Metal has no negative-height viewport";

    // The scene's own camera, built the way the parser builds it.
    SceneCamera camera(1920, 1080, -1.0, 1.0);
    const Eigen::Matrix4d compatibility_vp = camera.GetViewProjectionMatrix();
    const Eigen::Matrix4d metal_vp         = MetalViewProjection(compatibility_vp);

    // The author's canvas corners plus its centre and an off-centre point, so a
    // sign error cannot cancel against symmetry.
    const std::array<Eigen::Vector4d, 5> author_points {
        Eigen::Vector4d { -960.0, -540.0, 0.0, 1.0 }, Eigen::Vector4d { -960.0, 540.0, 0.0, 1.0 },
        Eigen::Vector4d { 960.0, -540.0, 0.0, 1.0 },  Eigen::Vector4d { 960.0, 540.0, 0.0, 1.0 },
        Eigen::Vector4d { -300.0, 210.0, 0.0, 1.0 },
    };

    for (const auto& point : author_points) {
        const Eigen::Vector4d compatibility_clip = compatibility_vp * point;
        const Eigen::Vector4d metal_clip         = metal_vp * point;

        const auto want = ClipToWindowVulkan(compatibility_clip, vulkan_viewport);
        const auto got  = ClipToWindowMetal(metal_clip, metal_viewport);
        EXPECT_NEAR(want.x(), got.x(), 1e-9);
        EXPECT_NEAR(want.y(), got.y(), 1e-9);

        // Both APIs clip depth to [0, 1] and `Ortho` already maps into it, so
        // no depth remap is folded either. Asserted, not assumed.
        EXPECT_TRUE(MetalDepthInClipRange(metal_clip.z(), metal_clip.w()));
    }

    // A y-flip inserted anywhere in the fold is exactly the regression this
    // guards: with it, the top and bottom canvas edges swap window rows.
    Eigen::Matrix4d flipped_fold = Eigen::Matrix4d::Identity();
    flipped_fold(1, 1)           = -1.0;
    const Eigen::Matrix4d wrong_vp = flipped_fold * metal_vp;
    const Eigen::Vector4d top      = author_points[1];
    const auto correct = ClipToWindowMetal(metal_vp * top, metal_viewport);
    const auto wrong   = ClipToWindowMetal(wrong_vp * top, metal_viewport);
    EXPECT_GT(std::abs(correct.y() - wrong.y()), 1.0)
        << "a spurious clip-space flip has to move the image";
}

TEST(MetalProjection, NegativeHeightViewportsCoverTheSameWindowRows)
{
    const VulkanViewportBox negative { .x = 12.0, .y = 40.0 + 200.0, .width = 320.0,
                                       .height = -200.0 };
    const auto              metal = ToMetalViewport(negative);
    EXPECT_DOUBLE_EQ(metal.origin_x, 12.0);
    EXPECT_DOUBLE_EQ(metal.origin_y, 40.0);
    EXPECT_DOUBLE_EQ(metal.width, 320.0);
    EXPECT_DOUBLE_EQ(metal.height, 200.0);
}

// ---------------------------------------------------------------------------
// Reflection

TEST(MetalShaderReflection, ReadsTheUniformLayoutAndVertexInputs)
{
    MetalShaderReflection reflection;
    std::string           error;
    ASSERT_TRUE(ParseMetalShaderReflection(kReflectionJson, reflection, &error)) << error;

    ASSERT_NE(reflection.uniformBlock(), nullptr);
    EXPECT_EQ(reflection.uniformBlock()->size, 128u);
    ASSERT_TRUE(reflection.hasMember("g_ModelViewProjectionMatrix"));
    EXPECT_EQ(reflection.member("g_ModelViewProjectionMatrix")->offset, 0u);
    EXPECT_EQ(reflection.member("g_Alpha")->offset, 64u);
    EXPECT_FALSE(reflection.hasMember("g_Bones"));
    ASSERT_EQ(reflection.inputs.size(), 2u);
    EXPECT_EQ(reflection.inputs[0].name, "a_Position");
    EXPECT_EQ(reflection.inputs[0].format, "r32g32b32_sfloat");
    EXPECT_EQ(reflection.descriptors.size(), 3u);
}

TEST(MetalShaderReflection, RefusesAResourceOutsideDescriptorSetZero)
{
    constexpr std::string_view bad = R"({
      "descriptor_bindings": [
        { "name": "Globals", "set": 1, "binding": 0, "descriptor": "uniform_buffer" }
      ]
    })";
    MetalShaderReflection reflection;
    std::string           error;
    EXPECT_FALSE(ParseMetalShaderReflection(bad, reflection, &error));
    EXPECT_FALSE(error.empty());
}

// ---------------------------------------------------------------------------
// Device-dependent

#ifdef __APPLE__
TEST(MetalDevice, TranslatedShaderConventionsAreWhatTheBackendBindsAgainst)
{
    if (! MetalDeviceAvailable()) {
        GTEST_SKIP() << "no Metal device on this machine; the device-backed checks did not run";
    }

    // The two conventions the backend depends on and cannot re-derive: the
    // entry point is renamed, and a resource's Metal slot is its SPIR-V
    // binding index within its own argument-table namespace.
    const auto program = TranslatedProgram();
    for (const auto& stage : program->stages) {
        EXPECT_EQ(stage.entry_point, "main_");
        EXPECT_NE(stage.entry_point, "main");
        for (const auto& binding : stage.bindings) {
            EXPECT_EQ(binding.set, 0u);
            EXPECT_EQ(binding.slot, binding.binding);
        }
    }
}
#endif
