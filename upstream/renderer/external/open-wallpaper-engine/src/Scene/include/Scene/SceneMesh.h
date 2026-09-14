#pragma once
#include <vector>
#include <memory>
#include <cstddef>
#include <cstdint>
#include <climits>
#include <atomic>
#include <span>
#include <string>

#include "SceneVertexArray.h"
#include "SceneIndexArray.h"
#include "SceneMaterial.h"

namespace wallpaper
{
class SceneMesh {
public:
	struct DrawRange {
		uint32_t indexOffset {0};
		uint32_t indexCount {0};
	};

	class Submesh {
	public:
		std::size_t VertexCount() const { return m_vertexArrays.size(); }
		std::size_t IndexCount() const { return m_indexArrays.size(); }

		const SceneVertexArray& GetVertexArray(const std::size_t index) const { return m_vertexArrays[index]; }
		const SceneIndexArray& GetIndexArray(const std::size_t index) const { return m_indexArrays[index]; }

		SceneVertexArray& GetVertexArray(const std::size_t index) { return m_vertexArrays[index]; }
		SceneIndexArray& GetIndexArray(const std::size_t index) { return m_indexArrays[index]; }

		void AddIndexArray(SceneIndexArray&& array) {
			m_indexArrays.emplace_back(std::move(array));
		}
		void AddVertexArray(SceneVertexArray&& array) {
			m_vertexArrays.emplace_back(std::move(array));
		}

		const std::vector<DrawRange>& DrawRanges() const { return m_drawRanges; }
		std::vector<DrawRange>& DrawRanges() { return m_drawRanges; }
		void SetDrawRanges(std::span<const DrawRange> ranges) {
			m_drawRanges.assign(ranges.begin(), ranges.end());
		}

		uint32_t material_slot {0};
		std::string output_override;

	private:
		std::vector<SceneVertexArray> m_vertexArrays;
		std::vector<SceneIndexArray> m_indexArrays;
		std::vector<DrawRange> m_drawRanges;
	};

	SceneMesh(bool dynamic = false):m_dynamic(dynamic),m_dirty(false),
		m_data(std::make_shared<Data>()) {}

	std::size_t VertexCount() const { return HasSubmeshZero() ? SubmeshZero().VertexCount() : 0; }
	std::size_t IndexCount() const { return HasSubmeshZero() ? SubmeshZero().IndexCount() : 0; }

	MeshPrimitive Primitive() const { return m_primitive; }
	uint32_t PointSize() const { return m_pointSize; }

	bool Dynamic() const { return m_dynamic; }
	const auto& Dirty() const { return m_dirty; }
	auto& Dirty() { return m_dirty; }
	void SetDirty() {
		m_dirty.store(true);
		m_dirty_generation.fetch_add(1);
	}
	uint64_t DirtyGeneration() const { return m_dirty_generation.load(); }

	uint32_t ID() const { return m_id; };
	void SetID(uint32_t v) { m_id = v; };

	const SceneVertexArray& GetVertexArray(const std::size_t index) const { return SubmeshZero().GetVertexArray(index); }
	const SceneIndexArray& GetIndexArray(const std::size_t index) const { return SubmeshZero().GetIndexArray(index); }

	SceneVertexArray& GetVertexArray(const std::size_t index) { return SubmeshZero().GetVertexArray(index); }
	SceneIndexArray& GetIndexArray(const std::size_t index) { return SubmeshZero().GetIndexArray(index); }


	void AddIndexArray(SceneIndexArray&& array) {
		SubmeshZero().AddIndexArray(std::move(array));
	}
	void AddVertexArray(SceneVertexArray&& array) {
		SubmeshZero().AddVertexArray(std::move(array));
	}
	void AddMaterial(SceneMaterial&& material) {
		m_materialSlots.emplace_back(std::make_shared<SceneMaterial>(std::move(material)));
	}

	void SetPrimitive(MeshPrimitive v) {  m_primitive = v; }
	void SetPointSize(uint32_t v) { m_pointSize = v; }


	SceneMaterial* Material() { return m_materialSlots.empty() ? nullptr : m_materialSlots[0].get(); }
	const SceneMaterial* Material() const { return MaterialForSlot(0); }
	SceneMaterial* MaterialForSlot(uint32_t slot) {
		if (slot >= m_materialSlots.size()) return nullptr;
		if (m_materialSlots[slot] == nullptr) return nullptr;
		return m_materialSlots[slot].get();
	}
	const SceneMaterial* MaterialForSlot(uint32_t slot) const {
		if (slot >= m_materialSlots.size()) return nullptr;
		if (m_materialSlots[slot] == nullptr) return nullptr;
		return m_materialSlots[slot].get();
	}

	const std::vector<Submesh>& Submeshes() const { return m_data->submeshes; }
	std::vector<Submesh>& Submeshes() { return m_data->submeshes; }

	const std::vector<std::shared_ptr<SceneMaterial>>& MaterialSlots() const { return m_materialSlots; }
	std::vector<std::shared_ptr<SceneMaterial>>& MaterialSlots() { return m_materialSlots; }
	std::shared_ptr<SceneMaterial> MaterialSlotPtr(std::size_t index = 0) const {
		return (index < m_materialSlots.size()) ? m_materialSlots[index] : nullptr;
	}

	const std::vector<DrawRange>& DrawRanges() const {
		static const std::vector<DrawRange> kEmpty;
		return HasSubmeshZero() ? SubmeshZero().DrawRanges() : kEmpty;
	}
	std::vector<DrawRange>& DrawRanges() { return SubmeshZero().DrawRanges(); }
	void SetDrawRanges(std::span<const DrawRange> ranges) { SubmeshZero().SetDrawRanges(ranges); }

	void ChangeMeshDataFrom(const SceneMesh& o) {
		m_data = o.m_data;
	}

private:
	struct Data {
		std::vector<Submesh> submeshes;
	};

	bool HasSubmeshZero() const { return ! m_data->submeshes.empty(); }
	const Submesh& SubmeshZero() const { return m_data->submeshes[0]; }
	Submesh& SubmeshZero() {
		if (m_data->submeshes.empty()) m_data->submeshes.emplace_back();
		return m_data->submeshes[0];
	}

	uint32_t m_id { std::numeric_limits<uint32_t>::max() };
	MeshPrimitive m_primitive {MeshPrimitive::TRIANGLE};
	uint32_t m_pointSize {1};
	bool m_dynamic;
	std::atomic<bool> m_dirty;
	std::atomic<uint64_t> m_dirty_generation {0};

	std::shared_ptr<Data> m_data;
	std::vector<std::shared_ptr<SceneMaterial>> m_materialSlots;
};

}
