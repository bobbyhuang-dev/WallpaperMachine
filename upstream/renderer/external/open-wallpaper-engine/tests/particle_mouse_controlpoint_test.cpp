#include "Particle/ParticleEmitter.h"
#include "Interface/IParticleRawGener.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Particle/WPParticleRawGener.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "WPParticleParser.hpp"
#include "wpscene/WPParticleObject.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <cmath>
#include <memory>
#include <vector>

namespace wallpaper
{
namespace
{

class CapturingParticleRawGener final : public IParticleRawGener {
public:
    void GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                   SceneMesh&,
                   ParticleRawGenSpecOp&,
                   ParticleRenderScale render_scale) override {
        last_render_scale = render_scale;
        particles.clear();
        for (const auto& instance : instances) {
            if (instance) {
                const auto instanceParticles = instance->Particles();
                particles.insert(particles.end(), instanceParticles.begin(), instanceParticles.end());
            }
        }
    }

    std::vector<Particle> particles;
    ParticleRenderScale   last_render_scale;
};

std::unique_ptr<ParticleSubSystem> MakeTestSubsystem(ParticleSystem& system,
                                                     std::shared_ptr<SceneMesh> mesh,
                                                     ParticleRawGenSpecOp spec = {}) {
    if (! spec) {
        spec = [](const Particle&, const ParticleRawGenSpec&) {
        };
    }
    return std::make_unique<ParticleSubSystem>(system,
                                               std::move(mesh),
                                               8,
                                               1.0,
                                               1,
                                               1.0,
                                               ParticleSubSystem::SpawnType::STATIC,
                                               std::move(spec));
}

Particle FirstSpawnedParticle(ParticleEmittOp&                      emitter,
                              std::span<const ParticleControlpoint> controlpoints) {
    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers;

    emitter(particles, initializers, 8, 1.0, controlpoints);

    EXPECT_FALSE(particles.empty());
    return particles.front();
}

std::shared_ptr<SceneMesh> MakeParticleMesh(std::size_t count) {
    auto mesh = std::make_shared<SceneMesh>(true);
    mesh->AddVertexArray(SceneVertexArray(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
            { WE_IN_COLOR.data(), VertexType::FLOAT4 },
            { WE_IN_TEXCOORDC2.data(), VertexType::FLOAT2 },
        },
        count * 4));
    mesh->AddIndexArray(SceneIndexArray(count));
    return mesh;
}

float FirstParticleRawRenderHalfSize(const SceneMesh& mesh) {
    const auto& vertex_array = mesh.GetVertexArray(0);
    const auto  offsets      = vertex_array.GetAttrOffsetMap();
    const auto  texcoord     = offsets.find(WE_IN_TEXCOORDVEC4);
    if (texcoord == offsets.end()) {
        ADD_FAILURE() << "particle mesh is missing " << WE_IN_TEXCOORDVEC4;
        return 0.0f;
    }
    const auto  offset =
        static_cast<std::size_t>(texcoord->second.offset / sizeof(float));
    return vertex_array.Data()[offset + 3];
}

void AddSingleSizedParticleEmitter(ParticleSubSystem& subsystem, float size) {
    subsystem.AddEmitter([size](std::vector<Particle>& particles,
                                std::vector<ParticleInitOp>&,
                                uint32_t,
                                double,
                                std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;

        Particle particle;
        ParticleModify::InitLifetime(particle, 10.0f);
        ParticleModify::InitSize(particle, size);
        particles.emplace_back(particle);
    });
}

TEST(ParticleMouseControlpoint, EmitterControlpointOffsetsBoxSpawnOrigin) {
    ParticleBoxEmitterArgs args {};
    args.directions    = { 0.0f, 0.0f, 0.0f };
    args.minDistance   = { 0.0f, 0.0f, 0.0f };
    args.maxDistance   = { 0.0f, 0.0f, 0.0f };
    args.emitSpeed     = 1.0f;
    args.orgin         = { 10.0f, 20.0f, 30.0f };
    args.instantaneous = 1;
    args.controlpoint  = 2;

    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[2].offset = Eigen::Vector3d(5.0, 6.0, 7.0);

    auto           emitter  = ParticleBoxEmitterArgs::MakeEmittOp(args);
    const Particle particle = FirstSpawnedParticle(emitter, controlpoints);

    EXPECT_FLOAT_EQ(particle.position.x(), 15.0f);
    EXPECT_FLOAT_EQ(particle.position.y(), 26.0f);
    EXPECT_FLOAT_EQ(particle.position.z(), 37.0f);
}

TEST(ParticleMouseControlpoint, EmitterParsesAudioResponseParameters) {
    wpscene::Emitter emitter;

    ASSERT_TRUE(emitter.FromJson(nlohmann::json {
        { "name", "boxrandom" },
        { "audioprocessingmode", 2 },
        { "controlpoint", 3 },
        { "rate", 4.0f },
    }));

    EXPECT_EQ(emitter.audioprocessingmode, 2u);
    EXPECT_EQ(emitter.controlpoint, 3);
    EXPECT_FLOAT_EQ(emitter.rate, 4.0f);
}

TEST(ParticleMouseControlpoint, InstanceoverridePreservesUserBindings) {
    wpscene::ParticleInstanceoverride override;

    ASSERT_TRUE(override.FromJosn(nlohmann::json {
        { "alpha", { { "user", "alpha_property" }, { "value", 0.25f } } },
        { "size", { { "user", "size_property" }, { "value", 2.0f } } },
        { "colorn", { { "user", "color_property" }, { "value", "0.1 0.2 0.3" } } },
    }));

    EXPECT_TRUE(override.enabled);
    EXPECT_FLOAT_EQ(override.alpha, 0.25f);
    EXPECT_FLOAT_EQ(override.size, 2.0f);
    EXPECT_TRUE(override.overColorn);
    EXPECT_EQ(override.bindings.at("alpha"), "alpha_property");
    EXPECT_EQ(override.bindings.at("size"), "size_property");
    EXPECT_EQ(override.bindings.at("colorn"), "color_property");
}

TEST(ParticleMouseControlpoint, OverrideColornIsAbsoluteNormalizedColor) {
    auto override        = std::make_shared<wpscene::ParticleInstanceoverride>();
    override->enabled    = true;
    override->overColorn = true;
    override->colorn     = { 0.25f, 0.5f, 0.75f };

    auto init = WPParticleParser::genOverrideInitOp(override);

    Particle particle;
    ParticleModify::InitColor(particle, 0.2, 0.2, 0.2);
    init(particle, 0.0);

    EXPECT_FLOAT_EQ(particle.color.x(), 0.25f);
    EXPECT_FLOAT_EQ(particle.color.y(), 0.5f);
    EXPECT_FLOAT_EQ(particle.color.z(), 0.75f);
}

TEST(ParticleMouseControlpoint, OverrideInitializerReadsRuntimeMutatedState) {
    auto override     = std::make_shared<wpscene::ParticleInstanceoverride>();
    override->enabled = true;
    override->size    = 2.0f;
    override->speed   = 3.0f;

    auto init = WPParticleParser::genOverrideInitOp(override);

    Particle first;
    ParticleModify::InitSize(first, 1.0f);
    ParticleModify::InitVelocity(first, 1.0f, 0.0f, 0.0f);
    init(first, 0.0);
    EXPECT_FLOAT_EQ(first.size, 2.0f);
    EXPECT_FLOAT_EQ(first.velocity.x(), 3.0f);

    override->size  = 4.0f;
    override->speed = 0.5f;

    Particle second;
    ParticleModify::InitSize(second, 1.0f);
    ParticleModify::InitVelocity(second, 2.0f, 0.0f, 0.0f);
    init(second, 0.0);
    EXPECT_FLOAT_EQ(second.size, 4.0f);
    EXPECT_FLOAT_EQ(second.velocity.x(), 1.0f);
}

TEST(ParticleMouseControlpoint, ControlpointAttractReadsThresholdAndOrigin) {
    nlohmann::json json {
        { "name", "controlpointattract" },
        { "controlpoint", 1 },
        { "scale", 10.0f },
        { "threshold", 4.0f },
        { "origin", { 2.0f, 0.0f, 0.0f } },
    };

    WPParticleParser parser;
    auto             op = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());

    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[1].offset = Eigen::Vector3d(3.0, 0.0, 0.0);

    std::array<Particle, 1> particles {};
    ParticleModify::MoveTo(particles[0], 0.0, 0.0, 0.0);

    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };
    op(info);

    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 0.0f);

    json["threshold"] = 6.0f;
    op                = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());
    particles[0].velocity = Eigen::Vector3f::Zero();
    op(info);

    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 10.0f);

    json["threadhold"] = 4.0f;
    op                 = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());
    particles[0].velocity = Eigen::Vector3f::Zero();
    op(info);

    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 10.0f);
}

TEST(ParticleMouseControlpoint, ControlpointAttractNormalizesNegativeIndexSafely) {
    nlohmann::json json {
        { "name", "controlpointattract" },
        { "controlpoint", -1 },
        { "scale", 10.0f },
        { "threshold", 6.0f },
    };

    WPParticleParser parser;
    auto             op = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());

    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[0].offset = Eigen::Vector3d(5.0, 0.0, 0.0);

    std::array<Particle, 1> particles {};
    ParticleModify::MoveTo(particles[0], 0.0, 0.0, 0.0);

    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };
    op(info);

    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 10.0f);
}

TEST(ParticleMouseControlpoint, ControlpointAttractSkipsZeroDistance) {
    nlohmann::json json {
        { "name", "controlpointattract" },
        { "controlpoint", 1 },
        { "scale", 10.0f },
        { "threshold", 6.0f },
        { "origin", { 2.0f, 0.0f, 0.0f } },
    };

    WPParticleParser parser;
    auto             op = parser.genParticleOperatorOp(
        json,
        std::make_shared<wpscene::ParticleInstanceoverride>());

    std::array<ParticleControlpoint, 8> controlpoints {};
    controlpoints[1].offset = Eigen::Vector3d(3.0, 0.0, 0.0);

    std::array<Particle, 1> particles {};
    ParticleModify::MoveTo(particles[0], 5.0, 0.0, 0.0);

    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };
    op(info);

    EXPECT_TRUE(std::isfinite(particles[0].velocity.x()));
    EXPECT_TRUE(std::isfinite(particles[0].velocity.y()));
    EXPECT_TRUE(std::isfinite(particles[0].velocity.z()));
    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 0.0f);
}

TEST(ParticleMouseControlpoint, MouseControlpointUpdatesEmitterOrigin) {
    Scene scene;
    scene.ortho[0]        = 200;
    scene.ortho[1]        = 100;
    scene.frameTime       = 1.0;
    scene.pointerPosition = { 0.75f, 0.25f };

    auto              mesh = std::make_shared<SceneMesh>(true);
    ParticleSystem    system(scene);
    ParticleSubSystem subsystem(system,
                                mesh,
                                8,
                                1.0,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });
    auto              controlpoints = subsystem.Controlpoints();
    controlpoints[0].link_mouse     = true;
    controlpoints[0].base_offset    = Eigen::Vector3d(1.0, 2.0, 3.0);
    controlpoints[0].offset         = controlpoints[0].base_offset;

    subsystem.UpdateMouseControlpoints();

    EXPECT_DOUBLE_EQ(controlpoints[0].offset.x(), 151.0);
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.y(), 77.0);
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.z(), 3.0);
}

TEST(ParticleMouseControlpoint, MouseControlpointUsesOwnerNodeLocalSpace) {
    Scene scene;
    scene.ortho[0]        = 200;
    scene.ortho[1]        = 100;
    scene.frameTime       = 1.0;
    scene.pointerPosition = { 0.75f, 0.25f };

    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(Eigen::Vector3f(100.0f, 50.0f, 0.0f));
    node->SetScale(Eigen::Vector3f(2.0f, 1.0f, 1.0f));

    auto              mesh = std::make_shared<SceneMesh>(true);
    ParticleSystem    system(scene);
    ParticleSubSystem subsystem(system,
                                mesh,
                                8,
                                1.0,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });
    subsystem.SetOwnerNode(node);
    auto              controlpoints = subsystem.Controlpoints();
    controlpoints[0].link_mouse     = true;
    controlpoints[0].base_offset    = Eigen::Vector3d(1.0, 2.0, 3.0);
    controlpoints[0].offset         = controlpoints[0].base_offset;

    subsystem.UpdateMouseControlpoints();

    EXPECT_DOUBLE_EQ(controlpoints[0].offset.x(), 26.0);
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.y(), 27.0);
    EXPECT_DOUBLE_EQ(controlpoints[0].offset.z(), 3.0);
}

TEST(ParticleMouseControlpoint, RawParticleSizeCompensatesOwnerScale) {
    Scene scene;
    scene.frameTime = 1.0;

    auto owner = std::make_shared<SceneNode>();
    owner->SetScale(Eigen::Vector3f(6.0f, 6.0f, 1.0f));

    auto mesh = MakeParticleMesh(1);

    ParticleSystem system(scene);
    system.gener = std::make_unique<WPParticleRawGener>();

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetOwnerNode(owner);
    subsystem->AddEmitter([](std::vector<Particle>& particles,
                             std::vector<ParticleInitOp>&,
                             uint32_t,
                             double,
                             std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;

        Particle particle;
        ParticleModify::InitLifetime(particle, 10.0f);
        ParticleModify::InitSize(particle, 48.0f);
        particles.emplace_back(particle);
    });

    subsystem->Emitt();

    EXPECT_FLOAT_EQ(FirstParticleRawRenderHalfSize(*mesh), 4.0f);
}

TEST(ParticleMouseControlpoint, RawParticleSizeUsesAbsoluteOwnerScale) {
    Scene scene;
    scene.frameTime = 1.0;

    auto owner = std::make_shared<SceneNode>();
    owner->SetScale(Eigen::Vector3f(-6.0f, -6.0f, 1.0f));

    auto mesh = MakeParticleMesh(1);

    ParticleSystem system(scene);
    system.gener = std::make_unique<WPParticleRawGener>();

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetOwnerNode(owner);
    subsystem->AddEmitter([](std::vector<Particle>& particles,
                             std::vector<ParticleInitOp>&,
                             uint32_t,
                             double,
                             std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;

        Particle particle;
        ParticleModify::InitLifetime(particle, 10.0f);
        ParticleModify::InitSize(particle, 48.0f);
        particles.emplace_back(particle);
    });

    subsystem->Emitt();

    EXPECT_FLOAT_EQ(FirstParticleRawRenderHalfSize(*mesh), 4.0f);
}

TEST(ParticleMouseControlpoint, RawParticleSizeUsesIsotropicNonuniformOwnerScale) {
    Scene scene;
    scene.frameTime = 1.0;

    auto owner = std::make_shared<SceneNode>();
    owner->SetScale(Eigen::Vector3f(2.0f, 6.0f, 1.0f));
    owner->SetRotation(Eigen::Vector3f(0.0f, 0.0f, 0.5f));

    auto mesh = MakeParticleMesh(1);

    ParticleSystem system(scene);
    system.gener = std::make_unique<WPParticleRawGener>();

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetOwnerNode(owner);
    AddSingleSizedParticleEmitter(*subsystem, 48.0f);

    subsystem->Emitt();

    EXPECT_FLOAT_EQ(FirstParticleRawRenderHalfSize(*mesh), 6.0f);
}

TEST(ParticleMouseControlpoint, RawParticleSizeUsesEffectiveParentAndChildScale) {
    Scene scene;
    scene.frameTime = 1.0;

    auto parent = std::make_shared<SceneNode>();
    parent->SetScale(Eigen::Vector3f(2.0f, 3.0f, 1.0f));

    auto owner = std::make_shared<SceneNode>();
    owner->SetScale(Eigen::Vector3f(4.0f, 2.0f, 1.0f));
    parent->AppendChild(owner);

    auto mesh = MakeParticleMesh(1);

    ParticleSystem system(scene);
    system.gener = std::make_unique<WPParticleRawGener>();

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetOwnerNode(owner);
    AddSingleSizedParticleEmitter(*subsystem, 48.0f);

    subsystem->Emitt();

    EXPECT_NEAR(FirstParticleRawRenderHalfSize(*mesh), 24.0f / 7.0f, 1.0e-5f);
}

TEST(ParticleMouseControlpoint, RawGeneratorReceivesIndependentOwnerScaleAxes) {
    Scene scene;
    scene.frameTime = 1.0;

    auto owner = std::make_shared<SceneNode>();
    owner->SetScale(Eigen::Vector3f(2.0f, 6.0f, 1.0f));
    owner->SetRotation(Eigen::Vector3f(0.0f, 0.0f, 0.5f));

    auto* rawGener = new CapturingParticleRawGener();
    auto  mesh     = std::make_shared<SceneMesh>(true);

    ParticleSystem system(scene);
    system.gener.reset(rawGener);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetOwnerNode(owner);
    AddSingleSizedParticleEmitter(*subsystem, 48.0f);

    subsystem->Emitt();

    EXPECT_FLOAT_EQ(rawGener->last_render_scale.inverse_x, 0.5f);
    EXPECT_FLOAT_EQ(rawGener->last_render_scale.inverse_y, 1.0f / 6.0f);
    EXPECT_FLOAT_EQ(rawGener->last_render_scale.isotropic_inverse, 0.25f);
}

TEST(ParticleMouseControlpoint, MovementIntegratesAfterControlpointAttractUpdatesVelocity) {
    Scene scene;
    scene.frameTime = 1.0;

    auto* rawGener = new CapturingParticleRawGener();
    auto  mesh     = std::make_shared<SceneMesh>(true);

    ParticleSystem system(scene);
    system.gener.reset(rawGener);

    ParticleSubSystem subsystem(system,
                                mesh,
                                8,
                                1.0,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });

    subsystem.Controlpoints()[0].offset = Eigen::Vector3d(10.0, 0.0, 0.0);

    subsystem.AddEmitter([](std::vector<Particle>& particles,
                            std::vector<ParticleInitOp>&,
                            uint32_t,
                            double,
                            std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;

        Particle particle;
        ParticleModify::MoveTo(particle, 0.0, 0.0, 0.0);
        ParticleModify::InitVelocity(particle, 1.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 2.0f);
        particles.emplace_back(particle);
    });

    WPParticleParser parser;
    subsystem.AddOperator(parser.genParticleOperatorOp(nlohmann::json {
                            { "name", "movement" },
                            { "gravity", { 0.0f, 0.0f, 0.0f } },
                            { "drag", 0.0f },
                        },
                                                       std::make_shared<wpscene::ParticleInstanceoverride>()));
    subsystem.AddOperator(parser.genParticleOperatorOp(nlohmann::json {
                            { "name", "controlpointattract" },
                            { "controlpoint", 0 },
                            { "scale", 2.0f },
                            { "threshold", 20.0f },
                        },
                                                       std::make_shared<wpscene::ParticleInstanceoverride>()));

    subsystem.Emitt();

    ASSERT_EQ(rawGener->particles.size(), 1u);
    EXPECT_FLOAT_EQ(rawGener->particles[0].velocity.x(), 3.0f);
    EXPECT_FLOAT_EQ(rawGener->particles[0].position.x(), 3.0f);
}

TEST(ParticleMouseControlpoint, MovementOperatorReadsRuntimeMutatedSpeedOverride) {
    auto override     = std::make_shared<wpscene::ParticleInstanceoverride>();
    override->enabled = true;
    override->speed   = 2.0f;

    auto op = WPParticleParser::genParticleOperatorOp(
        nlohmann::json {
            { "name", "movement" },
            { "gravity", { 1.0f, 0.0f, 0.0f } },
            { "drag", 0.0f },
        },
        override);

    std::array<ParticleControlpoint, 8> controlpoints {};
    std::array<Particle, 1>             particles {};
    ParticleInfo info {
        .particles     = particles,
        .controlpoints = controlpoints,
        .time          = 0.0,
        .time_pass     = 1.0,
    };

    op(info);
    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 2.0f);

    override->speed = 0.5f;
    particles[0].velocity = Eigen::Vector3f::Zero();
    op(info);

    EXPECT_FLOAT_EQ(particles[0].velocity.x(), 0.5f);
}

TEST(ParticleMouseControlpoint, SubsystemRateOverrideControlsInitialEmissionTiming) {
    Scene scene;
    scene.frameTime = 1.0;

    auto* rawGener = new CapturingParticleRawGener();
    auto  mesh     = std::make_shared<SceneMesh>(true);

    ParticleSystem system(scene);
    system.gener.reset(rawGener);

    ParticleSubSystem subsystem(system,
                                mesh,
                                8,
                                0.5,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });
    subsystem.SetRateMultiplier([] {
        return 2.0;
    });
    subsystem.AddEmitter(WPParticleParser::genParticleEmittOp(wpscene::Emitter {
        .instantaneous = 0,
        .name          = "boxrandom",
        .rate          = 1.0f,
    }));
    subsystem.AddInitializer([](Particle& particle, double) {
        ParticleModify::InitLifetime(particle, 10.0f);
    });

    subsystem.Emitt();

    ASSERT_EQ(rawGener->particles.size(), 1u);
}

TEST(ParticleMouseControlpoint, SubsystemRateOverrideControlsRuntimeEmissionTiming) {
    Scene scene;
    scene.frameTime = 1.0;

    auto* rawGener = new CapturingParticleRawGener();
    auto  mesh     = std::make_shared<SceneMesh>(true);

    ParticleSystem system(scene);
    system.gener.reset(rawGener);

    double rate_override = 0.5;
    ParticleSubSystem subsystem(system,
                                mesh,
                                8,
                                1.0,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });
    subsystem.SetRateMultiplier([&rate_override] {
        return rate_override;
    });
    subsystem.AddEmitter(WPParticleParser::genParticleEmittOp(wpscene::Emitter {
        .instantaneous = 0,
        .name          = "boxrandom",
        .rate          = 1.0f,
    }));
    subsystem.AddInitializer([](Particle& particle, double) {
        ParticleModify::InitLifetime(particle, 10.0f);
    });

    subsystem.Emitt();
    EXPECT_TRUE(rawGener->particles.empty());

    rate_override = 2.0;
    subsystem.Emitt();

    ASSERT_EQ(rawGener->particles.size(), 2u);
}

TEST(ParticleMouseControlpoint, EmitterCountOverrideControlsInitialQuantity) {
    wpscene::Emitter emitter;
    emitter.name          = "boxrandom";
    emitter.rate          = 1.0f;
    emitter.instantaneous = 0;

    auto override     = std::make_shared<wpscene::ParticleInstanceoverride>();
    override->enabled = true;
    override->count   = 3.0f;

    auto op = WPParticleParser::genParticleEmittOp(emitter, false, override);

    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers;
    std::array<ParticleControlpoint, 8> controlpoints {};

    op(particles, initializers, 8, 1.0, controlpoints);

    EXPECT_EQ(particles.size(), 3u);
}

TEST(ParticleMouseControlpoint, EmitterCountOverrideControlsRuntimeQuantity) {
    wpscene::Emitter emitter;
    emitter.name          = "boxrandom";
    emitter.rate          = 1.0f;
    emitter.instantaneous = 0;

    auto override     = std::make_shared<wpscene::ParticleInstanceoverride>();
    override->enabled = true;
    override->count   = 1.0f;

    auto op = WPParticleParser::genParticleEmittOp(emitter, false, override);

    std::vector<Particle>       particles;
    std::vector<ParticleInitOp> initializers;
    std::array<ParticleControlpoint, 8> controlpoints {};

    op(particles, initializers, 8, 1.0, controlpoints);
    EXPECT_EQ(particles.size(), 1u);

    override->count = 3.0f;
    op(particles, initializers, 8, 1.0, controlpoints);

    EXPECT_EQ(particles.size(), 4u);
}

TEST(ParticleMouseControlpoint, ProjectPropertiesDriveInitialAndRuntimeRateAndCountOverrides) {
    Scene scene;
    scene.frameTime = 1.0;
    SceneRuntimeBootstrap bootstrap {
        .project_properties = {
            { "particle_rate", RuntimeScalarValue::Float(1.0f) },
            { "particle_count", RuntimeScalarValue::Float(2.0f) },
        },
    };
    scene.runtime = CreateSceneRuntimeContext(std::move(bootstrap));

    auto* rawGener = new CapturingParticleRawGener();
    auto  mesh     = std::make_shared<SceneMesh>(true);

    ParticleSystem system(scene);
    system.gener.reset(rawGener);

    auto override = std::make_shared<wpscene::ParticleInstanceoverride>();
    ASSERT_TRUE(override->FromJosn(nlohmann::json {
        { "rate", { { "user", "particle_rate" }, { "value", 1.0f } } },
        { "count", { { "user", "particle_count" }, { "value", 1.0f } } },
    }));
    for (const auto& [field, user] : override->bindings) {
        std::unique_ptr<DynamicValue> value;
        if (field == "rate") {
            value = std::make_unique<DynamicValue>(override->rate);
        } else if (field == "count") {
            value = std::make_unique<DynamicValue>(override->count);
        }
        ASSERT_NE(value, nullptr);
        auto* property_value = scene.runtime->FindPropertyValue(user);
        ASSERT_NE(property_value, nullptr);
        value->connect(property_value);
        scene.runtime->RegisterDynamicValueListener(
            std::move(value),
            [override, field](const DynamicValue& value) {
                if (field == "rate") {
                    override->rate = value.getFloat();
                } else if (field == "count") {
                    override->count = value.getFloat();
                }
            });
    }

    ParticleSubSystem subsystem(system,
                                mesh,
                                16,
                                1.0,
                                1,
                                1.0,
                                ParticleSubSystem::SpawnType::STATIC,
                                [](const Particle&, const ParticleRawGenSpec&) {
                                });
    subsystem.SetRateMultiplier([override] {
        return override->enabled ? static_cast<double>(override->rate) : 1.0;
    });
    subsystem.AddEmitter(WPParticleParser::genParticleEmittOp(wpscene::Emitter {
        .instantaneous = 0,
        .name          = "boxrandom",
        .rate          = 1.0f,
    }, false, override));
    subsystem.AddInitializer([](Particle& particle, double) {
        ParticleModify::InitLifetime(particle, 10.0f);
    });

    subsystem.Emitt();
    EXPECT_EQ(rawGener->particles.size(), 2u);

    scene.runtime->ApplyProjectPropertyOverride({
        { "particle_rate", RuntimeScalarValue::Float(2.0f) },
        { "particle_count", RuntimeScalarValue::Float(3.0f) },
    });
    subsystem.Emitt();

    EXPECT_EQ(rawGener->particles.size(), 8u);
}

} // namespace
} // namespace wallpaper
