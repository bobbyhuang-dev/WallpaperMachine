#include "StagingBuffer.hpp"
#include <algorithm>
#include <cstring>
#include <exception>
#include <limits>
#include <new>
#include "Util.hpp"
#include "Device.hpp"

using namespace wallpaper::vulkan;

namespace
{
bool CheckedAdd(VkDeviceSize left, VkDeviceSize right, VkDeviceSize& result) {
    if (right > std::numeric_limits<VkDeviceSize>::max() - left) return false;
    result = left + right;
    return true;
}

bool AlignCapacity(VkDeviceSize value, VkDeviceSize alignment, VkDeviceSize& result) {
    const auto remainder = value % alignment;
    return CheckedAdd(value, remainder == 0 ? 0 : alignment - remainder, result);
}

std::optional<VmaBufferParameters> CreateGpuBuffer(VmaAllocator allocator, VkBufferUsageFlags usage,
                                                   std::size_t size) {
    VmaBufferParameters buffer;
    VkBufferCreateInfo ci {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = nullptr,
        .size  = size,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | usage,
    };
    buffer.req_size = ci.size;
    VmaAllocationCreateInfo vma_info = {};
    vma_info.usage = VMA_MEMORY_USAGE_GPU_ONLY;
    VVK_CHECK_ACT(return std::nullopt, vvk::CreateBuffer(allocator, ci, vma_info, buffer.handle));
    return buffer;
}

void RecordCopyBuffer(const BufferParameters& dst_buf, const BufferParameters& src_buf,
                      vvk::CommandBuffer& cmd, std::span<VkBufferCopy> ranges) {
    cmd.CopyBuffer(src_buf.handle, dst_buf.handle, ranges);
    VkBufferMemoryBarrier barrier {
        .sType               = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask       = VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | VK_ACCESS_INDEX_READ_BIT |
                               VK_ACCESS_UNIFORM_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer              = dst_buf.handle,
        .offset              = 0,
        .size                = VK_WHOLE_SIZE,
    };
    cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT |
                            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                        VK_DEPENDENCY_BY_REGION_BIT,
                        barrier);
}
} // namespace

StagingBuffer::StagingBuffer(const Device& d, VkDeviceSize size, VkBufferUsageFlags usage)
    : m_device(d), m_size_step(size), m_usage(usage) {
    m_stage_buf.req_size = 0;
    m_gpu_buf.req_size = 0;
}

StagingBuffer::~StagingBuffer() {
    if (m_upload_pending) {
        // The renderer normally retires the transaction before destruction. Never
        // let automatic member destruction release storage of unknown completion.
        const auto result = m_device.handle().WaitIdle();
        if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST) {
            LOG_ERROR("cannot destroy renderer resources before GPU completion");
            std::terminate();
        }
        finishUpload(false);
    }
    destroy();
}

StagingBuffer::VirtualBlock* StagingBuffer::newVirtualBlock(VkDeviceSize size,
                                                          VkDeviceSize alignment) {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return nullptr;
    }
    auto it = std::find_if(m_virtual_blocks.begin(), m_virtual_blocks.end(),
                           [size, alignment](const auto& block) {
                               return !block.enabled && block.size >= size &&
                                      block.offset % alignment == 0;
                           });
    VirtualBlock candidate;
    if (it == m_virtual_blocks.end()) {
        VkDeviceSize end = 0;
        if (!m_virtual_blocks.empty() &&
            !CheckedAdd(m_virtual_blocks.back().offset, m_virtual_blocks.back().size, end))
            return nullptr;
        if (!AlignCapacity(end, alignment, candidate.offset)) return nullptr;
        candidate.size = std::max({size, m_size_step, candidate.offset});
        candidate.index = m_virtual_blocks.size();
        if (!CheckedAdd(candidate.offset, candidate.size, end) ||
            !AlignCapacity(end, 4, end) || end > std::numeric_limits<size_t>::max())
            return nullptr;
    } else {
        candidate = *it;
    }
    VmaVirtualBlockCreateInfo info = {};
    info.size = candidate.size;
    VVK_CHECK_ACT(return nullptr, vmaCreateVirtualBlock(&info, &candidate.handle));
    candidate.enabled = true;
    if (it == m_virtual_blocks.end()) {
        try {
            m_virtual_blocks.push_back(candidate);
        } catch (const std::bad_alloc&) {
            vmaDestroyVirtualBlock(candidate.handle);
            return nullptr;
        }
        return &m_virtual_blocks.back();
    }
    *it = candidate;
    return &*it;
}

bool StagingBuffer::increaseBuf(VkDeviceSize required_capacity) {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return false;
    }
    VkDeviceSize capacity;
    if (!m_stage_raw || !AlignCapacity(required_capacity, 4, capacity) ||
        capacity > std::numeric_limits<size_t>::max()) return false;
    const auto old_capacity = m_stage_buf.req_size;
    if (capacity <= old_capacity) return true;
    VmaBufferParameters replacement;
    if (!CreateStagingBuffer(m_device.vma_allocator(), static_cast<size_t>(capacity), replacement))
        return false;
    void* replacement_raw = nullptr;
    VVK_CHECK_BOOL_RE(replacement.handle.MapMemory(&replacement_raw));
    std::memcpy(replacement_raw, m_stage_raw, old_capacity);
    std::memset(static_cast<uint8_t*>(replacement_raw) + old_capacity, 0,
                static_cast<size_t>(capacity) - old_capacity);
    m_stage_buf.handle.UnMapMemory();
    m_stage_raw = nullptr;
    m_stage_buf = std::move(replacement);
    m_stage_raw = replacement_raw;
    m_gpu_buf.handle = nullptr;
    m_gpu_buf.req_size = 0;
    requireFullUpload();
    return true;
}

bool StagingBuffer::allocate() {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return false;
    }
    if (m_stage_buf.handle || m_stage_raw || !m_virtual_blocks.empty()) return false;
    VkDeviceSize capacity;
    if (m_size_step == 0 || !AlignCapacity(m_size_step, 4, capacity) ||
        capacity > std::numeric_limits<size_t>::max()) return false;
    VmaBufferParameters stage;
    if (!CreateStagingBuffer(m_device.vma_allocator(), static_cast<size_t>(capacity), stage))
        return false;
    void* raw = nullptr;
    VVK_CHECK_BOOL_RE(stage.handle.MapMemory(&raw));
    if (!newVirtualBlock(capacity, 1)) {
        stage.handle.UnMapMemory();
        return false;
    }
    std::memset(raw, 0, static_cast<size_t>(capacity));
    m_stage_buf = std::move(stage);
    m_stage_raw = raw;
    requireFullUpload();
    return true;
}

void StagingBuffer::destroy() {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return;
    }
    if (m_stage_raw) {
        m_stage_buf.handle.UnMapMemory();
        m_stage_raw = nullptr;
    }
    for (auto& block : m_virtual_blocks) {
        if (block.enabled) {
            vmaClearVirtualBlock(block.handle);
            vmaDestroyVirtualBlock(block.handle);
        }
    }
    m_virtual_blocks.clear();
    m_stage_buf.handle = nullptr;
    m_stage_buf.req_size = 0;
    m_gpu_buf.handle = nullptr;
    m_gpu_buf.req_size = 0;
    m_upload_pending = false;
    requireFullUpload();
}

bool StagingBuffer::allocateSubRef(VkDeviceSize size, StagingBufferRef& ref,
                                   VkDeviceSize alignment) {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return false;
    }
    if (!m_stage_raw) return false;
    if (size == 0) {
        ref = {};
        return true;
    }
    alignment = std::max<VkDeviceSize>(alignment, 1);
    if ((alignment & (alignment - 1)) != 0 || size > std::numeric_limits<size_t>::max())
        return false;
    VmaVirtualAllocationCreateInfo info = {};
    info.size = size;
    info.alignment = alignment;
    VmaVirtualAllocation allocation {};
    VkDeviceSize offset = 0;
    auto commit = [&](VirtualBlock& block) {
        // Blocks and allocation extents have already been checked against capacity.
        const auto absolute_offset = block.offset + offset;
        auto* raw = static_cast<uint8_t*>(m_stage_raw) + absolute_offset;
        if (std::find_if(raw, raw + size, [](uint8_t value) { return value != 0; }) != raw + size) {
            std::memset(raw, 0, static_cast<size_t>(size));
            markDirty(absolute_offset, size);
        }
        ref.size = size;
        ref.offset = absolute_offset;
        ref.m_allocation = allocation;
        ref.m_virtual_index = block.index;
    };
    for (auto& block : m_virtual_blocks) {
        if (block.enabled && block.size >= size && block.offset % alignment == 0 &&
            vmaVirtualAllocate(block.handle, &info, &allocation, &offset) == VK_SUCCESS) {
            commit(block);
            return true;
        }
    }
    const auto old_block_count = m_virtual_blocks.size();
    auto* block = newVirtualBlock(size, alignment);
    if (!block) return false;
    auto rollback = [&] {
        vmaClearVirtualBlock(block->handle);
        vmaDestroyVirtualBlock(block->handle);
        block->handle = VK_NULL_HANDLE;
        block->enabled = false;
        if (m_virtual_blocks.size() > old_block_count) m_virtual_blocks.pop_back();
    };
    if (vmaVirtualAllocate(block->handle, &info, &allocation, &offset) != VK_SUCCESS) {
        rollback();
        return false;
    }
    VkDeviceSize required_capacity;
    if (!CheckedAdd(block->offset, block->size, required_capacity) ||
        !increaseBuf(required_capacity)) {
        rollback();
        return false;
    }
    commit(*block);
    return true;
}

void StagingBuffer::unallocateSubRef(const StagingBufferRef& ref) {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return;
    }
    if (!ref) return;
    if (ref.m_virtual_index >= m_virtual_blocks.size() ||
        !m_virtual_blocks[ref.m_virtual_index].enabled) {
        LOG_ERROR("unallocate stagingbuffer failed: wrong index %zu", ref.m_virtual_index);
        return;
    }
    auto& block = m_virtual_blocks[ref.m_virtual_index];
    vmaVirtualFree(block.handle, ref.m_allocation);
    if (vmaIsVirtualBlockEmpty(block.handle)) {
        vmaDestroyVirtualBlock(block.handle);
        block.handle = VK_NULL_HANDLE;
        block.enabled = false;
    }
}

bool StagingBuffer::writeToBuf(const StagingBufferRef& ref, std::span<uint8_t> data,
                               size_t offset) {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return false;
    }
    if (!ref || !m_stage_raw || ref.m_virtual_index >= m_virtual_blocks.size() ||
        !m_virtual_blocks[ref.m_virtual_index].enabled ||
        ref.offset > m_stage_buf.req_size || ref.size > m_stage_buf.req_size - ref.offset) {
        LOG_ERROR("stage ref not available, index %zu", ref.m_virtual_index);
        return false;
    }
    if (offset > ref.size) {
        LOG_ERROR("staging buffer write offset %zu exceeds ref size %zu",
                  offset, static_cast<size_t>(ref.size));
        return false;
    }
    const auto size = std::min<VkDeviceSize>(ref.size - offset, data.size());
    if (size == 0) return true;
    const auto absolute_offset = ref.offset + offset;
    auto* raw = static_cast<uint8_t*>(m_stage_raw) + absolute_offset;
    if (std::memcmp(raw, data.data(), static_cast<size_t>(size)) == 0) return true;
    std::memcpy(raw, data.data(), static_cast<size_t>(size));
    markDirty(absolute_offset, size);
    return true;
}

bool StagingBuffer::fillBuf(const StagingBufferRef& ref, size_t offset, size_t size, uint8_t c) {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return false;
    }
    if (!ref || !m_stage_raw || ref.m_virtual_index >= m_virtual_blocks.size() ||
        !m_virtual_blocks[ref.m_virtual_index].enabled ||
        ref.offset > m_stage_buf.req_size || ref.size > m_stage_buf.req_size - ref.offset) {
        LOG_ERROR("stage ref not available, index %zu", ref.m_virtual_index);
        return false;
    }
    if (offset > ref.size) {
        LOG_ERROR("staging buffer fill offset %zu exceeds ref size %zu",
                  offset, static_cast<size_t>(ref.size));
        return false;
    }
    const auto effective_size = std::min<VkDeviceSize>(ref.size - offset, size);
    if (effective_size == 0) return true;
    const auto absolute_offset = ref.offset + offset;
    auto* raw = static_cast<uint8_t*>(m_stage_raw) + absolute_offset;
    if (std::find_if(raw, raw + effective_size, [c](uint8_t value) { return value != c; }) ==
        raw + effective_size) return true;
    std::memset(raw, c, static_cast<size_t>(effective_size));
    markDirty(absolute_offset, effective_size);
    return true;
}

void StagingBuffer::requireFullUpload() noexcept {
    m_full_upload_required = true;
    m_dirty_count = 0;
}

void StagingBuffer::markDirty(VkDeviceSize offset, VkDeviceSize size) {
    if (size == 0 || m_full_upload_required) return;
    VkDeviceSize end;
    if (!CheckedAdd(offset, size, end) || !AlignCapacity(end, 4, end) ||
        end > m_stage_buf.req_size) {
        // All writers validate their bounds before writing. Preserve a safe full
        // upload if a future caller violates the private range contract.
        requireFullUpload();
        return;
    }
    auto start = offset - offset % 4;
    size_t first = 0;
    while (first < m_dirty_count &&
           m_dirty_ranges[first].srcOffset + m_dirty_ranges[first].size < start) ++first;
    size_t last = first;
    while (last < m_dirty_count && m_dirty_ranges[last].srcOffset <= end) {
        start = std::min(start, m_dirty_ranges[last].srcOffset);
        end = std::max(end, m_dirty_ranges[last].srcOffset + m_dirty_ranges[last].size);
        ++last;
    }
    if (first == last && m_dirty_count == m_dirty_ranges.size()) {
        start = std::min(start, m_dirty_ranges[0].srcOffset);
        const auto& tail = m_dirty_ranges[m_dirty_count - 1];
        end = std::max(end, tail.srcOffset + tail.size);
        m_dirty_ranges[0] = {start, start, end - start};
        m_dirty_count = 1;
        return;
    }
    if (first == last) {
        for (size_t i = m_dirty_count; i > first; --i) m_dirty_ranges[i] = m_dirty_ranges[i - 1];
        ++m_dirty_count;
    } else {
        for (size_t i = last; i < m_dirty_count; ++i)
            m_dirty_ranges[first + 1 + i - last] = m_dirty_ranges[i];
        m_dirty_count -= last - first - 1;
    }
    m_dirty_ranges[first] = {start, start, end - start};
}

bool StagingBuffer::recordUpload(vvk::CommandBuffer& cmd) {
    if (m_upload_pending) {
        LOG_ERROR("staging buffer operation attempted while upload is pending");
        return false;
    }
    if (!m_stage_raw) return false;
    if (!m_gpu_buf.handle) {
        auto buffer = CreateGpuBuffer(m_device.vma_allocator(), m_usage, m_stage_buf.req_size);
        if (!buffer) return false;
        m_gpu_buf = std::move(*buffer);
        requireFullUpload();
    }
    VkBufferCopy full_range {0, 0, m_stage_buf.req_size};
    const auto ranges = m_full_upload_required
                            ? std::span<VkBufferCopy>(&full_range, 1)
                            : std::span<VkBufferCopy>(m_dirty_ranges.data(), m_dirty_count);
    for (const auto& range : ranges) {
        VVK_CHECK_BOOL_RE(vmaFlushAllocation(m_device.vma_allocator(),
                                             m_stage_buf.handle.Allocation(),
                                             range.srcOffset, range.size));
    }
    if (!ranges.empty()) RecordCopyBuffer(m_gpu_buf, m_stage_buf, cmd, ranges);
    // Even a no-copy command may bind this GPU buffer. Freeze both allocations
    // until the renderer proves completion or discards the recorded command.
    m_upload_pending = true;
    return true;
}

void StagingBuffer::finishUpload(bool completed) noexcept {
    if (!m_upload_pending) return;
    if (completed) {
        m_full_upload_required = false;
        m_dirty_count = 0;
    }
    m_upload_pending = false;
}

VkBuffer StagingBuffer::gpuBuf() const { return *m_gpu_buf.handle; }
