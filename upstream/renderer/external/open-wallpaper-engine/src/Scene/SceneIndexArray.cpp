#include "SceneIndexArray.h"
#include <cstring>
#include <utility>

using namespace wallpaper;

namespace
{
uint32_t* AllocateSlots(usize slots) {
    if (slots == 0) return nullptr;
    auto* data = new uint32_t[slots];
    std::memset(data, 0, slots * sizeof(uint32_t));
    return data;
}

bool QuadSlots(usize quadCount, SceneIndexWidth width, usize& slots) {
    const uint64_t per_quad = width == SceneIndexWidth::UInt32 ? 6ull : 3ull;
    uint64_t       count    = 0;
    if (! CheckedMulU64(quadCount, per_quad, count) ||
        count > std::numeric_limits<usize>::max() ||
        count > std::numeric_limits<usize>::max() / sizeof(uint32_t)) {
        return false;
    }
    slots = static_cast<usize>(count);
    return true;
}
} // namespace

SceneIndexArray::SceneIndexArray(std::size_t indexCount)
    : SceneIndexArray(indexCount, SceneIndexWidth::UInt16) {}

SceneIndexArray::SceneIndexArray(std::size_t quadCount, SceneIndexWidth width)
    : m_pData(nullptr), m_size(0), m_capacity(0), m_width(width) {
    usize slots = 0;
    if (! QuadSlots(quadCount, width, slots)) return;
    m_capacity = slots;
    m_pData    = AllocateSlots(slots);
}

SceneIndexArray::SceneIndexArray(std::span<const uint32_t> data)
    : m_size(data.size()), m_capacity(m_size), m_width(SceneIndexWidth::UInt16) {
    auto      dataSize = data.size();
    uint32_t* newdata  = new uint32_t[dataSize];
    std::memcpy(newdata, &data[0], DataSizeOf());
    m_pData = newdata;
};
SceneIndexArray::SceneIndexArray(SceneIndexArray&& o) noexcept
    : m_pData(std::exchange(o.m_pData, nullptr)),
      m_size(o.m_size),
      m_capacity(o.m_capacity),
      m_render_size(o.m_render_size),
      m_id(o.m_id),
      m_width(o.m_width) {}

SceneIndexArray::~SceneIndexArray() {
    if (m_pData != nullptr) delete[] m_pData;
}

bool SceneIndexArray::IncreaseCheckSet(size_t nsize) {
    if (nsize > CapacitySizeof()) return false;
    if (nsize > DataSizeOf()) {
        m_size = nsize / Unit_Byte_Size + (nsize % Unit_Byte_Size == 0 ? 0 : 1);
    }
    return true;
}
