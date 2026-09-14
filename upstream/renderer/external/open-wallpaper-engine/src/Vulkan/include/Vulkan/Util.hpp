#pragma once
#include "Instance.hpp"
#include "Parameters.hpp"

#include "vvk/vma_wrapper.hpp"

#include "vk_mem_alloc.h"

namespace wallpaper
{
namespace vulkan
{

inline bool CreateHostVisibleBuffer(VmaAllocator allocator,
                                    std::size_t  size,
                                    VkBufferUsageFlags usage,
                                    VmaBufferParameters& buffer) {
    VkBufferCreateInfo ci {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = nullptr,
        .size  = size,
        .usage = usage,
    };
    buffer.req_size = ci.size;

    VmaAllocationCreateInfo vma_info = {};
    vma_info.usage                   = VMA_MEMORY_USAGE_CPU_ONLY;
    VVK_CHECK_BOOL_RE(vvk::CreateBuffer(allocator, ci, vma_info, buffer.handle));
    return true;
}

inline bool CreateStagingBuffer(VmaAllocator allocator, std::size_t size,
                                VmaBufferParameters& buffer) {
    return CreateHostVisibleBuffer(
        allocator, size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, buffer);
}

inline bool CreateReadbackBuffer(VmaAllocator allocator, std::size_t size,
                                 VmaBufferParameters& buffer) {
    return CreateHostVisibleBuffer(
        allocator, size, VK_BUFFER_USAGE_TRANSFER_DST_BIT, buffer);
}
} // namespace vulkan
} // namespace wallpaper
