#include "Interface/IParticleRawGener.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include "Particle/WPParticleRawGener.h"
#include "Scene/Scene.h"
#include "Scene/SceneMesh.h"
#include "SpecTexs.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <span>
#include <vector>

namespace wallpaper
{
namespace
{

constexpr uint32_t kMeshCapacity = 16;

Particle LiveAt(const Eigen::Vector3f& pos, float size = 20.0f, float lifetime = 1.0f) {
    Particle particle;
    particle.position = pos;
    particle.size     = size;
    particle.lifetime = lifetime;
    return particle;
}

Particle DeadAt(const Eigen::Vector3f& pos) {
    Particle particle;
    particle.position = pos;
    particle.lifetime = 0.0f;
    return particle;
}

std::unique_ptr<ParticleInstance> MakeInstance(std::initializer_list<Particle> particles) {
    auto instance = std::make_unique<ParticleInstance>();
    instance->ParticlesVec().assign(particles);
    return instance;
}

// Attribute list copied from SetRopeParticleMesh; every attribute is FLOAT4.
void AddRopeParticleMesh(SceneMesh& mesh, uint32_t capacity, bool thick, bool trail = false) {
    std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { WE_IN_POSITIONVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
    };
    if (thick) {
        attrs.push_back({ WE_IN_TEXCOORDVEC4C2.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDVEC4C3.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDC4.data(), VertexType::FLOAT4 });
    } else {
        attrs.push_back({ WE_IN_TEXCOORDVEC3C2.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDC3.data(), VertexType::FLOAT4 });
    }
    attrs.push_back({ WE_IN_COLOR.data(), VertexType::FLOAT4 });
    mesh.AddVertexArray(SceneVertexArray(attrs, capacity * 4));
    mesh.AddIndexArray(SceneIndexArray(capacity));
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPE, true);
    mesh.GetVertexArray(0).SetOption(WE_CB_THICK_FORMAT, thick);
    if (trail) {
        mesh.GetVertexArray(0).SetOption(WE_PRENDER_TRAIL, true);
        mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPETRAIL, true);
    }
}

void GenRope(std::vector<std::unique_ptr<ParticleInstance>>& instances, SceneMesh& mesh,
             ParticleRenderScale scale) {
    WPParticleRawGener     gener;
    ParticleRawGenSpecOp   spec = [](const Particle&, const ParticleRawGenSpec&) {
    };
    gener.GenGLData(instances, mesh, spec, scale);
}

const float* QuadVertex(const SceneVertexArray& vertices, std::size_t quad, std::size_t vert) {
    return vertices.Data() + (quad * 4 + vert) * vertices.OneSize();
}

void ExpectVec3(const float* components, const Eigen::Vector3f& expected) {
    EXPECT_FLOAT_EQ(components[0], expected.x());
    EXPECT_FLOAT_EQ(components[1], expected.y());
    EXPECT_FLOAT_EQ(components[2], expected.z());
}

void ExpectSegment(const SceneVertexArray& vertices, std::size_t quad, const Eigen::Vector3f& start,
                   const Eigen::Vector3f& end, float trail_length, float trail_position) {
    const float* vertex = QuadVertex(vertices, quad, 0);
    ExpectVec3(vertex + 0, start);
    ExpectVec3(vertex + 4, end);
    EXPECT_FLOAT_EQ(vertex[7], trail_length);
    EXPECT_FLOAT_EQ(vertex[11], trail_position);
}

void ExpectUvCorners(const SceneVertexArray& vertices, std::size_t quad, bool thick) {
    const std::size_t uv_offset             = thick ? 20 : 16;
    const float       expected[4][2]        = { { 0.0f, 1.0f },
                                                { 1.0f, 1.0f },
                                                { 1.0f, 0.0f },
                                                { 0.0f, 0.0f } };
    for (std::size_t vert = 0; vert < 4; ++vert) {
        const float* uv = QuadVertex(vertices, quad, vert) + uv_offset;
        EXPECT_FLOAT_EQ(uv[0], expected[vert][0]) << "vert " << vert;
        EXPECT_FLOAT_EQ(uv[1], expected[vert][1]) << "vert " << vert;
    }
}

void ExpectNoNaN(const SceneVertexArray& vertices) {
    const float* data = vertices.Data();
    for (std::size_t i = 0; i < vertices.CapacitySize(); ++i) {
        EXPECT_TRUE(std::isfinite(data[i])) << i;
    }
}

struct SlotSnap {
    Particle                   particle;
    uint32_t                   trail_count { 0 };
    uint32_t                   trail_capacity { 0 };
    std::vector<Eigen::Vector3f> trail;
};

class CapturingParticleRawGener final : public IParticleRawGener {
public:
    void GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances, SceneMesh&,
                   ParticleRawGenSpecOp&, ParticleRenderScale) override {
        slots.clear();
        for (const auto& instance : instances) {
            if (! instance) continue;
            const auto particles = instance->Particles();
            const auto trails    = instance->Trails();
            for (std::size_t i = 0; i < particles.size(); ++i) {
                SlotSnap snap;
                snap.particle = particles[i];
                if (i < trails.size()) {
                    snap.trail_count    = trails[i].Count();
                    snap.trail_capacity = trails[i].Capacity();
                    snap.trail.reserve(snap.trail_count);
                    for (uint32_t age = 0; age < snap.trail_count; ++age) {
                        snap.trail.push_back(trails[i].At(age).position);
                    }
                }
                slots.push_back(std::move(snap));
            }
        }
    }

    std::vector<SlotSnap> slots;
};

std::unique_ptr<ParticleSubSystem> MakeTestSubsystem(ParticleSystem&            system,
                                                     std::shared_ptr<SceneMesh> mesh) {
    return std::make_unique<ParticleSubSystem>(system,
                                               std::move(mesh),
                                               8,
                                               1.0,
                                               1,
                                               1.0,
                                               ParticleSubSystem::SpawnType::STATIC,
                                               [](const Particle&, const ParticleRawGenSpec&) {
                                               });
}

TEST(ParticleRopeGeometry, ThreeLiveParticlesWithSubdivisionOneEmitTwoQuads) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       LiveAt({ 10.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 2u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 0.0f, 0.0f }, { 10.0f, 0.0f, 0.0f }, 3.0f, 0.0f);
    ExpectSegment(vertices, 1, { 10.0f, 0.0f, 0.0f }, { 20.0f, 0.0f, 0.0f }, 3.0f, 1.0f);
    ExpectUvCorners(vertices, 0, false);
}

TEST(ParticleRopeGeometry, DeadParticleBetweenLiveOnesIsSkippedAndNeighboursJoined) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }),
                                       DeadAt({ 100.0f, 0.0f, 0.0f }),
                                       LiveAt({ 20.0f, 0.0f, 0.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 1u * 3);
    ExpectSegment(mesh.GetVertexArray(0), 0, { 0.0f, 0.0f, 0.0f }, { 20.0f, 0.0f, 0.0f }, 2.0f,
                  0.0f);
}

TEST(ParticleRopeGeometry, RopeQuadsNeverSpanInstances) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }), LiveAt({ 1.0f, 0.0f, 0.0f }) }));
    instances.push_back(
        MakeInstance({ LiveAt({ 10.0f, 0.0f, 0.0f }), LiveAt({ 11.0f, 0.0f, 0.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 2u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 0.0f, 0.0f }, { 1.0f, 0.0f, 0.0f }, 2.0f, 0.0f);
    ExpectSegment(vertices, 1, { 10.0f, 0.0f, 0.0f }, { 11.0f, 0.0f, 0.0f }, 2.0f, 0.0f);
}

TEST(ParticleRopeGeometry, ZeroAndOneLiveParticleEmitNoQuads) {
    ParticleRenderScale scale;
    scale.rope_subdivision = 1;

    {
        SceneMesh mesh(MeshUpdate::PerFrame);
        AddRopeParticleMesh(mesh, kMeshCapacity, false);
        std::vector<std::unique_ptr<ParticleInstance>> instances;
        instances.push_back(MakeInstance({}));
        GenRope(instances, mesh, scale);
        EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
    }
    {
        SceneMesh mesh(MeshUpdate::PerFrame);
        AddRopeParticleMesh(mesh, kMeshCapacity, false);
        std::vector<std::unique_ptr<ParticleInstance>> instances;
        instances.push_back(MakeInstance({ LiveAt({ 1.0f, 2.0f, 3.0f }) }));
        GenRope(instances, mesh, scale);
        EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
    }
}

TEST(ParticleRopeGeometry, SubdivisionThreeSplitsThreeParticlesIntoSixQuadsThroughTheMiddle) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    const Eigen::Vector3f a { 0.0f, 0.0f, 0.0f };
    const Eigen::Vector3f b { 10.0f, 0.0f, 0.0f };
    const Eigen::Vector3f c { 20.0f, 0.0f, 0.0f };
    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ LiveAt(a), LiveAt(b), LiveAt(c) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 3;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 6u * 3);
    const float* first  = QuadVertex(vertices, 0, 0);
    const float* fourth = QuadVertex(vertices, 3, 0);
    const float* last   = QuadVertex(vertices, 5, 0);
    ExpectVec3(first + 0, a);
    EXPECT_FLOAT_EQ(first[7], 7.0f);
    EXPECT_FLOAT_EQ(first[11], 0.0f);
    EXPECT_NEAR(fourth[0], b.x(), 1.0e-5f);
    EXPECT_NEAR(fourth[1], b.y(), 1.0e-5f);
    EXPECT_NEAR(fourth[2], b.z(), 1.0e-5f);
    EXPECT_FLOAT_EQ(fourth[7], 7.0f);
    EXPECT_FLOAT_EQ(fourth[11], 3.0f);
    EXPECT_NEAR(last[4], c.x(), 1.0e-5f);
    EXPECT_NEAR(last[5], c.y(), 1.0e-5f);
    EXPECT_NEAR(last[6], c.z(), 1.0e-5f);
}

TEST(ParticleRopeGeometry, CoincidentParticlesEmitNoQuadAndNoNaN) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(
        MakeInstance({ LiveAt({ 4.0f, 5.0f, 6.0f }), LiveAt({ 4.0f, 5.0f, 6.0f }) }));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
    ExpectNoNaN(mesh.GetVertexArray(0));
}

TEST(ParticleRopeGeometry, ThickFormatWritesEndColourAndEndHalfSize) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true);

    Particle start = LiveAt({ 0.0f, 0.0f, 0.0f }, 8.0f);
    start.color    = { 1.0f, 0.0f, 0.0f };
    start.alpha    = 0.5f;
    Particle end   = LiveAt({ 10.0f, 0.0f, 0.0f }, 12.0f);
    end.color      = { 0.0f, 1.0f, 0.0f };
    end.alpha      = 0.25f;

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(MakeInstance({ start, end }));

    ParticleRenderScale scale;
    scale.isotropic_inverse = 0.5f;
    scale.rope_subdivision  = 1;
    GenRope(instances, mesh, scale);

    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 1u * 3);
    const float* vertex = QuadVertex(mesh.GetVertexArray(0), 0, 0);
    EXPECT_FLOAT_EQ(vertex[3], 2.0f);
    EXPECT_FLOAT_EQ(vertex[15], 3.0f);
    EXPECT_FLOAT_EQ(vertex[16], 0.0f);
    EXPECT_FLOAT_EQ(vertex[17], 1.0f);
    EXPECT_FLOAT_EQ(vertex[18], 0.0f);
    EXPECT_FLOAT_EQ(vertex[19], 0.25f);
    EXPECT_FLOAT_EQ(vertex[24], 1.0f);
    EXPECT_FLOAT_EQ(vertex[25], 0.0f);
    EXPECT_FLOAT_EQ(vertex[26], 0.0f);
    EXPECT_FLOAT_EQ(vertex[27], 0.5f);
}

TEST(ParticleRopeGeometry, InstanceBoundedOffsetIsAddedToRopePositions) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, false);

    auto instance = MakeInstance({ LiveAt({ 1.0f, 2.0f, 3.0f }), LiveAt({ 4.0f, 5.0f, 6.0f }) });
    instance->GetBoundedData().pos = { 100.0f, 200.0f, 300.0f };

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 1u * 3);
    ExpectSegment(mesh.GetVertexArray(0), 0, { 101.0f, 202.0f, 303.0f },
                  { 104.0f, 205.0f, 306.0f }, 2.0f, 0.0f);
}

void PushOldestFirst(ParticleTrailHistory& history, std::initializer_list<Eigen::Vector3f> points) {
    for (const auto& point : points) {
        history.Push({ .position = point });
    }
}

TEST(ParticleRopeGeometry, RopeTrailEmitsQuadsFromCurrentPositionAlongRecordedPoints) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance = MakeInstance({ LiveAt({ 0.0f, 30.0f, 0.0f }) });
    instance->TrailsVec().resize(1);
    instance->TrailsVec()[0].Reset(8);
    // Oldest first so At(0) is the newest recorded point.
    PushOldestFirst(instance->TrailsVec()[0],
                    { { 0.0f, 0.0f, 0.0f }, { 0.0f, 10.0f, 0.0f }, { 0.0f, 20.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 3u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 30.0f, 0.0f }, { 0.0f, 20.0f, 0.0f }, 3.0f, 0.0f);
    ExpectSegment(vertices, 1, { 0.0f, 20.0f, 0.0f }, { 0.0f, 10.0f, 0.0f }, 3.0f, 1.0f);
    ExpectSegment(vertices, 2, { 0.0f, 10.0f, 0.0f }, { 0.0f, 0.0f, 0.0f }, 3.0f, 2.0f);
}

TEST(ParticleRopeGeometry, FullTrailHistoryMovesTheLastPointByTrailFraction) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance = MakeInstance({ LiveAt({ 0.0f, 30.0f, 0.0f }) });
    instance->TrailsVec().resize(1);
    instance->TrailsVec()[0].Reset(3);
    PushOldestFirst(instance->TrailsVec()[0],
                    { { 0.0f, 0.0f, 0.0f }, { 0.0f, 10.0f, 0.0f }, { 0.0f, 20.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    scale.trail_fraction   = 0.5f;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 3u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 30.0f, 0.0f }, { 0.0f, 20.0f, 0.0f }, 3.0f, 0.0f);
    ExpectSegment(vertices, 2, { 0.0f, 10.0f, 0.0f }, { 0.0f, 5.0f, 0.0f }, 3.0f, 2.0f);
}

TEST(ParticleRopeGeometry, EmptyHistoryAndDeadParticleDrawNothing) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance = MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }), DeadAt({ 5.0f, 0.0f, 0.0f }) });
    instance->TrailsVec().resize(2);
    instance->TrailsVec()[0].Reset(4);
    instance->TrailsVec()[1].Reset(4);
    PushOldestFirst(instance->TrailsVec()[1],
                    { { 5.0f, 0.0f, 0.0f }, { 6.0f, 0.0f, 0.0f }, { 7.0f, 0.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    EXPECT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 0u);
}

TEST(ParticleRopeGeometry, TwoParticlesTrailsAreNeverJoined) {
    SceneMesh mesh(MeshUpdate::PerFrame);
    AddRopeParticleMesh(mesh, kMeshCapacity, true, true);

    auto instance =
        MakeInstance({ LiveAt({ 0.0f, 0.0f, 0.0f }), LiveAt({ 10.0f, 0.0f, 0.0f }) });
    instance->TrailsVec().resize(2);
    instance->TrailsVec()[0].Reset(4);
    instance->TrailsVec()[1].Reset(4);
    PushOldestFirst(instance->TrailsVec()[0], { { -1.0f, 0.0f, 0.0f } });
    PushOldestFirst(instance->TrailsVec()[1], { { 11.0f, 0.0f, 0.0f } });

    std::vector<std::unique_ptr<ParticleInstance>> instances;
    instances.push_back(std::move(instance));

    ParticleRenderScale scale;
    scale.rope_subdivision = 1;
    GenRope(instances, mesh, scale);

    const auto& vertices = mesh.GetVertexArray(0);
    ASSERT_EQ(mesh.GetIndexArray(0).RenderDataCount(), 2u * 3);
    ExpectSegment(vertices, 0, { 0.0f, 0.0f, 0.0f }, { -1.0f, 0.0f, 0.0f }, 1.0f, 0.0f);
    ExpectSegment(vertices, 1, { 10.0f, 0.0f, 0.0f }, { 11.0f, 0.0f, 0.0f }, 1.0f, 0.0f);
}

// The recording clock and the frame clock are kept apart in these tests -- half
// a period per tick, in binary-exact numbers -- so a tick either records a point
// or does not, and a particle's birth point can be told from a recorded one.
TEST(ParticleTrailHistory, FirstTickRecordsBirthPosition) {
    Scene scene;
    scene.frameTime = 0.125;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.25 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 3.0, 4.0, 5.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    subsystem->Emitt();

    ASSERT_EQ(cap->slots.size(), 1u);
    ASSERT_EQ(cap->slots[0].trail_count, 1u);
    ExpectVec3(cap->slots[0].trail[0].data(), { 3.0f, 4.0f, 5.0f });
    EXPECT_FLOAT_EQ(cap->slots[0].particle.position.x(), 4.25f);
}

TEST(ParticleTrailHistory, LaterTicksAppendPointsUpToCapacityThenDropOldest) {
    Scene scene;
    scene.frameTime = 0.125;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.25 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 3.0, 4.0, 5.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    // The birth point on the first tick, then one recorded point on every
    // second tick, until the history is full and the oldest is dropped.
    for (int tick = 1; tick <= 10; ++tick) {
        subsystem->Emitt();
        ASSERT_EQ(cap->slots.size(), 1u) << tick;
        EXPECT_EQ(cap->slots[0].trail_count, static_cast<uint32_t>(std::min(1 + tick / 2, 4)))
            << tick;
    }
    ASSERT_EQ(cap->slots[0].trail.size(), 4u);
    for (const auto& point : cap->slots[0].trail) {
        EXPECT_FALSE(point.x() == 3.0f && point.y() == 4.0f && point.z() == 5.0f);
    }
}

TEST(ParticleTrailHistory, TrailPeriodFractionStaysInUnitInterval) {
    Scene scene;
    scene.frameTime = 0.1;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.1 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 0.0, 0.0, 0.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    for (int tick = 0; tick < 6; ++tick) {
        subsystem->Emitt();
        const float fraction = subsystem->TrailPeriodFraction();
        EXPECT_GE(fraction, 0.0f) << tick;
        EXPECT_LT(fraction, 1.0f) << tick;
    }
}

TEST(ParticleTrailHistory, ZeroFrameTimeRecordsNothing) {
    Scene scene;
    scene.frameTime = 0.1;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.1 });
    subsystem->AddEmitter([](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                             uint32_t, double, std::span<const ParticleControlpoint>) {
        if (! particles.empty()) return;
        Particle particle;
        ParticleModify::MoveTo(particle, 0.0, 0.0, 0.0);
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        ParticleModify::InitLifetime(particle, 10.0f);
        particles.emplace_back(particle);
    });

    subsystem->Emitt();
    subsystem->Emitt();
    ASSERT_EQ(cap->slots.size(), 1u);
    const uint32_t count = cap->slots[0].trail_count;
    ASSERT_GE(count, 1u);

    scene.frameTime = 0.0;
    subsystem->Emitt();
    ASSERT_EQ(cap->slots.size(), 1u);
    EXPECT_EQ(cap->slots[0].trail_count, count);
}

TEST(ParticleTrailHistory, RespawnedParticleRestartsTrailHistoryAtNewBirth) {
    Scene scene;
    scene.frameTime = 0.125;

    auto* cap  = new CapturingParticleRawGener();
    auto  mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    ParticleSystem system(scene);
    system.gener.reset(cap);

    auto subsystem = MakeTestSubsystem(system, mesh);
    subsystem->SetTrail({ .samples = 4, .period = 0.25 });
    int spawn = 0;
    subsystem->AddEmitter([&spawn](std::vector<Particle>& particles, std::vector<ParticleInitOp>&,
                                   uint32_t, double, std::span<const ParticleControlpoint>) {
        for (const auto& particle : particles) {
            if (particle.lifetime > 0.0f) return;
        }
        Particle particle;
        if (spawn == 0) {
            ParticleModify::MoveTo(particle, 3.0, 4.0, 5.0);
            ParticleModify::InitLifetime(particle, 0.15f);
        } else {
            ParticleModify::MoveTo(particle, 9.0, 8.0, 7.0);
            ParticleModify::InitLifetime(particle, 10.0f);
        }
        ParticleModify::InitVelocity(particle, 10.0, 0.0, 0.0);
        if (particles.empty()) particles.emplace_back(particle);
        else particles[0] = particle;
        ++spawn;
    });

    subsystem->Emitt();
    ASSERT_EQ(cap->slots.size(), 1u);
    ASSERT_EQ(cap->slots[0].trail_count, 1u);
    ExpectVec3(cap->slots[0].trail[0].data(), { 3.0f, 4.0f, 5.0f });

    subsystem->Emitt();
    subsystem->Emitt();

    ASSERT_EQ(cap->slots.size(), 1u);
    ASSERT_EQ(cap->slots[0].trail_count, 1u);
    ExpectVec3(cap->slots[0].trail[0].data(), { 9.0f, 8.0f, 7.0f });
}

} // namespace
} // namespace wallpaper
