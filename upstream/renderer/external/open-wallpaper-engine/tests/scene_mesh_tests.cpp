#include <array>
#include <memory>
#include <span>
#include <vector>

#include <gtest/gtest.h>

#include "Scene/SceneMesh.h"

namespace
{
using namespace wallpaper;

SceneVertexArray MakeVertexArray(float x, float y) {
    SceneVertexArray array(
        { { "a_Position", VertexType::FLOAT2 } },
        2);
    const std::array<float, 2> vertex { x, y };
    array.AddVertex(vertex.data());
    return array;
}

SceneIndexArray MakeIndexArray(std::initializer_list<uint32_t> indices) {
    const std::vector<uint32_t> data(indices);
    return SceneIndexArray(std::span<const uint32_t>(data));
}

TEST(SceneMesh, AddVertexArray_UsesSubmeshZeroCompat) {
    SceneMesh mesh;

    mesh.AddVertexArray(MakeVertexArray(1.0f, 2.0f));
    mesh.AddIndexArray(MakeIndexArray({ 0, 1, 2 }));

    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    EXPECT_EQ(mesh.VertexCount(), 1u);
    EXPECT_EQ(mesh.IndexCount(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].VertexCount(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].IndexCount(), 1u);
    EXPECT_EQ(mesh.GetVertexArray(0).VertexCount(), 1u);
    EXPECT_EQ(mesh.GetIndexArray(0).DataCount(), 3u);
}

TEST(SceneMesh, AddMaterial_AppendsMaterialSlotAndMaterialReturnsSlotZero) {
    SceneMesh    mesh;
    SceneMaterial material;
    material.name = "slot-zero";
    SceneMaterial second;
    second.name = "slot-one";

    mesh.AddMaterial(std::move(material));
    mesh.AddMaterial(std::move(second));

    ASSERT_NE(mesh.Material(), nullptr);
    ASSERT_EQ(mesh.MaterialSlots().size(), 2u);
    ASSERT_NE(mesh.MaterialSlots()[0], nullptr);
    ASSERT_NE(mesh.MaterialSlots()[1], nullptr);
    EXPECT_EQ(mesh.MaterialSlots()[0].get(), mesh.Material());
    EXPECT_EQ(mesh.Material()->name, "slot-zero");
    EXPECT_EQ(mesh.MaterialSlots()[1]->name, "slot-one");
}

TEST(SceneMesh, MaterialForSlotBoundsChecks) {
    SceneMesh    mesh;
    SceneMaterial body;
    body.name = "body";
    SceneMaterial eyes;
    eyes.name = "eyes";

    mesh.AddMaterial(std::move(body));
    mesh.AddMaterial(std::move(eyes));

    EXPECT_EQ(mesh.MaterialForSlot(0)->name, "body");
    EXPECT_EQ(mesh.MaterialForSlot(1)->name, "eyes");
    EXPECT_EQ(mesh.MaterialForSlot(2), nullptr);

    const SceneMesh& const_mesh = mesh;
    EXPECT_EQ(const_mesh.MaterialForSlot(0)->name, "body");
    EXPECT_EQ(const_mesh.MaterialForSlot(1)->name, "eyes");
    EXPECT_EQ(const_mesh.MaterialForSlot(2), nullptr);
}

TEST(SceneMesh, SetDirtyAdvancesGeneration) {
    SceneMesh mesh;
    const auto initial_generation = mesh.DirtyGeneration();

    mesh.SetDirty();

    EXPECT_TRUE(mesh.Dirty().load());
    EXPECT_GT(mesh.DirtyGeneration(), initial_generation);
}

TEST(SceneMesh, ChangeMeshDataFromSharesSubmeshesButNotMaterialSlots) {
    SceneMesh source;
    source.AddVertexArray(MakeVertexArray(1.0f, 2.0f));
    source.AddIndexArray(MakeIndexArray({ 0, 1, 2 }));
    SceneMaterial source_material;
    source_material.name = "source";
    source.AddMaterial(std::move(source_material));

    SceneMesh destination;
    SceneMaterial destination_material;
    destination_material.name = "destination";
    destination.AddMaterial(std::move(destination_material));

    destination.ChangeMeshDataFrom(source);

    ASSERT_EQ(destination.Submeshes().size(), 1u);
    destination.Submeshes()[0].AddVertexArray(MakeVertexArray(3.0f, 4.0f));
    EXPECT_EQ(source.VertexCount(), 2u);
    ASSERT_NE(destination.Material(), nullptr);
    EXPECT_EQ(destination.Material()->name, "destination");
    ASSERT_EQ(destination.MaterialSlots().size(), 1u);
    EXPECT_EQ(destination.MaterialSlots()[0].get(), destination.Material());
}

TEST(SceneMesh, DrawRangesCompatRoutesToSubmeshZero) {
    SceneMesh mesh;
    const std::vector<SceneMesh::DrawRange> ranges {
        { .indexOffset = 3, .indexCount = 6 },
        { .indexOffset = 9, .indexCount = 12 },
    };

    mesh.SetDrawRanges(ranges);

    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    EXPECT_EQ(mesh.DrawRanges().size(), 2u);
    EXPECT_EQ(mesh.Submeshes()[0].DrawRanges().size(), 2u);
    EXPECT_EQ(mesh.DrawRanges()[0].indexOffset, 3u);
    EXPECT_EQ(mesh.DrawRanges()[0].indexCount, 6u);
    EXPECT_EQ(mesh.Submeshes()[0].DrawRanges()[1].indexOffset, 9u);
    EXPECT_EQ(mesh.Submeshes()[0].DrawRanges()[1].indexCount, 12u);
}

TEST(SceneMesh, EmptyConstDrawRangesReturnsEmptyVector) {
    const SceneMesh mesh;

    EXPECT_TRUE(mesh.DrawRanges().empty());
}

TEST(SceneMesh, SubmeshCarriesMaterialSlotIndex) {
    SceneMesh mesh;
    mesh.Submeshes().emplace_back();

    mesh.Submeshes()[0].material_slot = 3;

    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 3u);
}

TEST(SceneMesh, SubmeshCarriesOutputOverrideForMaskPasses) {
    SceneMesh mesh;
    mesh.Submeshes().emplace_back();

    mesh.Submeshes()[0].output_override = "_rt_puppet_mask";

    EXPECT_EQ(mesh.Submeshes()[0].output_override, "_rt_puppet_mask");
}
} // namespace
