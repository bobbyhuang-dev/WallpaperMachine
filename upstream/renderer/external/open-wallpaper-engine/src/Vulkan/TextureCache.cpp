
#include "Shader.hpp"
#include "Swapchain.hpp"
#include "TextureCache.hpp"
#include "Device.hpp"
#include "Util.hpp"

#include "Image.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Core/MapSet.hpp"
#include "Core/ArrayHelper.hpp"
#include "Utils/AutoDeletor.hpp"
#include "Utils/Hash.h"
#include "include/Vulkan/Parameters.hpp"
#include "vvk/vulkan_wrapper.hpp"

#include <vulkan/vulkan_metal.h>

#include <cmath>
#include <cstdio>
#include <memory>
#include <optional>

using namespace wallpaper;
using namespace wallpaper::vulkan;

namespace wallpaper
{
namespace vulkan
{
VkFormat ToVkType(TextureFormat tf) {
    switch (tf) {
    case TextureFormat::BC1: return VK_FORMAT_BC1_RGBA_UNORM_BLOCK;
    case TextureFormat::BC2: return VK_FORMAT_BC2_UNORM_BLOCK;
    case TextureFormat::BC3: return VK_FORMAT_BC3_UNORM_BLOCK;
    case TextureFormat::R8: return VK_FORMAT_R8_UNORM;
    case TextureFormat::RG8: return VK_FORMAT_R8G8_UNORM;
    case TextureFormat::RGB8: return VK_FORMAT_R8G8B8_UNORM;
    case TextureFormat::RGBA8: return VK_FORMAT_R8G8B8A8_UNORM;
    default: assert(false); return VK_FORMAT_R8G8B8A8_UNORM;
    }
}

VkSamplerAddressMode ToVkType(wallpaper::TextureWrap sam) {
    using namespace wallpaper;
    switch (sam) {
    case TextureWrap::CLAMP_TO_EDGE: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    case TextureWrap::REPEAT:
    default: return VK_SAMPLER_ADDRESS_MODE_REPEAT;
    }
}
VkFilter ToVkType(wallpaper::TextureFilter sam) {
    using namespace wallpaper;
    switch (sam) {
    case TextureFilter::LINEAR: return VK_FILTER_LINEAR;
    case TextureFilter::NEAREST:
    default: return VK_FILTER_NEAREST;
    }
}

VkSamplerCreateInfo GenRenderTargetSamplerInfo() {
    return VkSamplerCreateInfo {
        .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext                   = nullptr,
        .magFilter               = VK_FILTER_NEAREST,
        .minFilter               = VK_FILTER_NEAREST,
        .mipmapMode              = VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .addressModeU            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .anisotropyEnable        = false,
        .maxAnisotropy           = 1.0f,
        .compareEnable           = false,
        .compareOp               = VK_COMPARE_OP_NEVER,
        .minLod                  = 0.0f,
        .maxLod                  = 1.0f,
        .borderColor             = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = false,
    };
}
} // namespace vulkan
} // namespace wallpaper

namespace
{
bool SetError(std::string* error, std::string message) {
    if (error != nullptr) *error = std::move(message);
    return false;
}

void* ExportMetalDeviceHandle(const Device& device, std::string* error) {
    auto export_metal_objects = reinterpret_cast<PFN_vkExportMetalObjectsEXT>(
        device.handle().Dispatch().vkGetDeviceProcAddr(*device.handle(),
                                                       "vkExportMetalObjectsEXT"));
    if (export_metal_objects == nullptr) {
        SetError(error, "vkExportMetalObjectsEXT is not available on this Vulkan device");
        return nullptr;
    }

    VkExportMetalDeviceInfoEXT device_info {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT,
        .pNext = nullptr,
    };
    VkExportMetalObjectsInfoEXT export_info {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
        .pNext = &device_info,
    };
    export_metal_objects(*device.handle(), &export_info);
    if (device_info.mtlDevice == nullptr) {
        SetError(error, "vkExportMetalObjectsEXT returned a null Metal device");
        return nullptr;
    }

    return device_info.mtlDevice;
}

VkSamplerCreateInfo GenSamplerInfo(TextureKey key) {
    auto& sam = key.sample;

    VkSamplerCreateInfo sampler_info { .sType            = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                                       .pNext            = nullptr,
                                       .magFilter        = ToVkType(sam.magFilter),
                                       .minFilter        = (ToVkType(sam.minFilter)),
                                       .mipmapMode       = VK_SAMPLER_MIPMAP_MODE_LINEAR,
                                       .addressModeU     = (ToVkType(sam.wrapS)),
                                       .addressModeV     = (ToVkType(sam.wrapT)),
                                       .addressModeW     = (ToVkType(sam.wrapT)),
                                       .anisotropyEnable = (false),
                                       .maxAnisotropy    = (1.0f),
                                       .compareEnable    = (false),
                                       .compareOp        = VK_COMPARE_OP_NEVER,
                                       .minLod           = (0.0f),
                                       .maxLod           = (1.0f),
                                       .borderColor      = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
                                       .unnormalizedCoordinates = (false) };
    return sampler_info;
}

VkResult TransImgLayout(const vvk::Queue& queue, vvk::CommandBuffer& cmd,
                        const ImageParameters& image, VkImageLayout layout,
                        VkFence fence = VK_NULL_HANDLE) {
    VkResult result;
    do {
        result = cmd.Begin(VkCommandBufferBeginInfo {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = nullptr,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        if (result != VK_SUCCESS) break;

        VkImageSubresourceRange subresourceRange {
            .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel   = 0,
            .levelCount     = VK_REMAINING_MIP_LEVELS,
            .baseArrayLayer = 0,
            .layerCount     = VK_REMAINING_ARRAY_LAYERS,
        };
        {
            VkImageMemoryBarrier out_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = 0,
                .dstAccessMask    = VK_ACCESS_MEMORY_READ_BIT,
                .oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout        = layout,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                VK_DEPENDENCY_BY_REGION_BIT,
                                out_bar);
        }
        result = cmd.End();
        if (result != VK_SUCCESS) break;

        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = cmd.address(),
        };
        result = queue.Submit(sub_info, fence);
    } while (false);
    return result;
}

std::optional<vvk::DeviceMemory> AllocateMemory(const vvk::Device& device, vvk::PhysicalDevice gpu,
                                                VkMemoryRequirements  reqs,
                                                VkMemoryPropertyFlags property,
                                                void*                 pNext = NULL) {
    VkPhysicalDeviceMemoryProperties pros = gpu.GetMemoryProperties().memoryProperties;
    for (uint32_t i = 0; i < pros.memoryTypeCount; ++i) {
        if ((reqs.memoryTypeBits & (1 << i)) && (pros.memoryTypes[i].propertyFlags & property)) {
            VkMemoryAllocateInfo memory_allocate_info { .sType =
                                                            VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                                        .pNext           = pNext,
                                                        .allocationSize  = reqs.size,
                                                        .memoryTypeIndex = i };
            vvk::DeviceMemory    mem;
            VkResult             res = device.AllocateMemory(memory_allocate_info, mem);
            if (res == VK_SUCCESS) {
                return mem;
            } else {
                VVK_CHECK(res);
                return std::nullopt;
            }
        }
    }
    LOG_ERROR("vulkan allocate memory failed, no memory match requires");
    return std::nullopt;
}

std::optional<ExImageParameters>
CreateImportedMetalTextureImage(const Device& device, void* metal_texture, TextureSample sample,
                                VkSampler sampler, uint32_t width, uint32_t height,
                                std::string* error) {
    if (metal_texture == nullptr) {
        SetError(error, "cannot import a null Metal texture");
        return std::nullopt;
    }

    ExImageParameters image;

    VkImportMetalTextureInfoEXT import_texture_info {
        .sType      = VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT,
        .pNext      = nullptr,
        .plane      = VK_IMAGE_ASPECT_COLOR_BIT,
        .mtlTexture = reinterpret_cast<MTLTexture_id>(metal_texture),
    };
    VkImageCreateInfo image_info {
        .sType                 = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext                 = &import_texture_info,
        .imageType             = VK_IMAGE_TYPE_2D,
        .format                = VK_FORMAT_B8G8R8A8_UNORM,
        .extent                = VkExtent3D { .width = width, .height = height, .depth = 1 },
        .mipLevels             = 1,
        .arrayLayers           = 1,
        .samples               = VK_SAMPLE_COUNT_1_BIT,
        .tiling                = VK_IMAGE_TILING_OPTIMAL,
        .usage                 = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode           = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .initialLayout         = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    image.extent = image_info.extent;
    image.layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    if (const VkResult result = device.handle().CreateImage(image_info, image.handle);
        result != VK_SUCCESS) {
        VVK_CHECK(result);
        SetError(error, "failed to create Vulkan image for imported video frame");
        return std::nullopt;
    }

    {
        VkImageViewCreateInfo view_info {
            .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext    = nullptr,
            .image    = *image.handle,
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format   = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange =
                VkImageSubresourceRange {
                    .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel   = 0,
                    .levelCount     = 1,
                    .baseArrayLayer = 0,
                    .layerCount     = 1,
                },
        };
        if (const VkResult result = device.handle().CreateImageView(view_info, image.view);
            result != VK_SUCCESS) {
            VVK_CHECK(result);
            SetError(error, "failed to create Vulkan image view for imported video frame");
            return std::nullopt;
        }
    }

    TextureKey tex_key {
        .width        = static_cast<i32>(width),
        .height       = static_cast<i32>(height),
        .usage        = TexUsage::COLOR,
        .format       = TextureFormat::RGBA8,
        .sample       = sample,
        .mipmap_level = 1,
    };
    if (sampler != VK_NULL_HANDLE) {
        image.external_sampler = sampler;
    } else {
        if (const VkResult result =
                device.handle().CreateSampler(GenSamplerInfo(tex_key), image.sampler);
            result != VK_SUCCESS) {
            VVK_CHECK(result);
            SetError(error, "failed to create Vulkan sampler for imported video frame");
            return std::nullopt;
        }
    }

    return image;
}

// DRM fourcc codes we emit. We currently only render R8G8B8A8_UNORM and
// B8G8R8A8_UNORM into the ExSwapchain, so those are the only mappings.
// Vulkan component order X-Y-Z-W maps to the *first-byte-in-memory* ordering
// used by DRM fourccs ('AB24' = little-endian 'AB24' bytes = A, B, 2, 4 →
// DRM_FORMAT_ABGR8888).
static uint32_t VkFormatToDrmFourcc(VkFormat fmt) {
    switch (fmt) {
    case VK_FORMAT_R8G8B8A8_UNORM: return 0x34324241u; // DRM_FORMAT_ABGR8888
    case VK_FORMAT_B8G8R8A8_UNORM: return 0x34324152u; // DRM_FORMAT_ARGB8888
    default: return 0u;
    }
}

std::optional<ExImageParameters> CreateExImage(uint32_t width, uint32_t height, VkFormat format,
                                               VkImageTiling       tiling,
                                               VkSamplerCreateInfo sampler_info,
                                               VkImageUsageFlags usage, const vvk::Device& device,
                                               const vvk::PhysicalDevice& gpu) {
    ExImageParameters image;
    do {
        // Iteration 1a: switch the external handle type from OPAQUE_FD to
        // real Linux DMA-BUF so the FD is importable outside this Vulkan
        // instance. The OPTIMAL code path would additionally use
        // VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT and pick a modifier from
        // a queried list; we keep LINEAR-only for now so that consumers
        // can mmap the buffer directly (the iteration 4 milestone).
        if (tiling != VK_IMAGE_TILING_LINEAR) {
            LOG_INFO("[ex-image] OPTIMAL tiling requested; downgrading to LINEAR "
                     "because the DRM-format-modifier path is not yet wired up");
            tiling = VK_IMAGE_TILING_LINEAR;
        }

        VkExternalMemoryImageCreateInfo ex_info {
            .sType       = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext       = NULL,
            .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        VkExportMemoryAllocateInfo ex_mem_info {
            .sType       = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .pNext       = NULL,
            .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        VkImageCreateInfo info {
            .sType                 = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext                 = &ex_info,
            .imageType             = VK_IMAGE_TYPE_2D,
            .format                = format,
            .extent                = VkExtent3D { .width = width, .height = height, .depth = 1 },
            .mipLevels             = 1,
            .arrayLayers           = 1,
            .samples               = VK_SAMPLE_COUNT_1_BIT,
            .tiling                = tiling,
            .usage                 = usage,
            .sharingMode           = VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .initialLayout         = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        image.extent = info.extent;
        image.layout = VK_IMAGE_LAYOUT_GENERAL;

        VVK_CHECK_ACT(break, device.CreateImage(info, image.handle));

        image.mem_reqs = device.GetImageMemoryRequirements(*image.handle);

        if (auto opt = AllocateMemory(
                device, gpu, image.mem_reqs, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &ex_mem_info);
            opt.has_value()) {
            image.mem = std::move(opt.value());
        } else
            break;

        VVK_CHECK_ACT(break, image.handle.BindMemory(*image.mem, 0));
        {
            VkImageViewCreateInfo createinfo {
                .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext    = nullptr,
                .image    = *image.handle,
                .viewType = VK_IMAGE_VIEW_TYPE_2D,
                .format   = format,
                .subresourceRange =
                    VkImageSubresourceRange {
                        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                        .baseMipLevel   = 0,
                        .levelCount     = 1,
                        .baseArrayLayer = 0,
                        .layerCount     = 1,
                    },
            };
            VVK_CHECK_ACT(break, device.CreateImageView(createinfo, image.view));
        }
        VVK_CHECK_ACT(break, device.CreateSampler(sampler_info, image.sampler));
        VVK_CHECK_ACT(break, image.mem.GetMemoryFdKHR(&image.fd));

        // Populate the DRM metadata so VulkanExSwapchain → ExHandle (and
        // eventually the waywallen-host process) can forward it to external
        // consumers without re-querying Vulkan.
        VkImageSubresource subres {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel   = 0,
            .arrayLayer = 0,
        };
        VkSubresourceLayout layout = device.GetImageSubresourceLayout(*image.handle, subres);
        image.plane0_offset        = layout.offset;
        image.plane0_stride        = static_cast<uint32_t>(layout.rowPitch);
        image.drm_modifier         = 0; // DRM_FORMAT_MOD_LINEAR
        image.drm_fourcc           = VkFormatToDrmFourcc(format);

        return image;

    } while (false);
    return std::nullopt;
}

inline std::optional<VmaImageParameters>
CreateImage(const Device& device, VkExtent3D extent, u32 miplevel, VkFormat format,
            VkSamplerCreateInfo sampler_info, VkImageUsageFlags usage,
            VmaMemoryUsage         mem_usage = VMA_MEMORY_USAGE_GPU_ONLY,
            VkSampleCountFlagBits  samples = VK_SAMPLE_COUNT_1_BIT) {
    VmaImageParameters image;
    do {
        if (samples != VK_SAMPLE_COUNT_1_BIT) {
            miplevel = 1;
            constexpr VkImageUsageFlags removed_msaa_usage =
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
            usage &= ~removed_msaa_usage;
            usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        }

        VkImageCreateInfo info {
            .sType                 = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext                 = nullptr,
            .imageType             = VK_IMAGE_TYPE_2D,
            .format                = format,
            .extent                = extent,
            .mipLevels             = miplevel,
            .arrayLayers           = 1,
            .samples               = samples,
            .tiling                = VK_IMAGE_TILING_OPTIMAL,
            .usage                 = usage,
            .sharingMode           = VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .initialLayout         = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        image.extent = info.extent;
        VmaAllocationCreateInfo vma_info {};
        vma_info.usage = mem_usage;
        VVK_CHECK_ACT(break,
                      vvk::CreateImage(device.vma_allocator(), info, vma_info, image.handle));

        image.mipmap_level = miplevel;
        {
            VkImageViewCreateInfo createinfo {
                .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext    = nullptr,
                .image    = *image.handle,
                .viewType = VK_IMAGE_VIEW_TYPE_2D,
                .format   = format,
                .subresourceRange =
                    VkImageSubresourceRange {
                        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                        .baseMipLevel   = 0,
                        .levelCount     = miplevel,
                        .baseArrayLayer = 0,
                        .layerCount     = 1,
                    },
            };
            VVK_CHECK_ACT(break, device.handle().CreateImageView(createinfo, image.view));
        }
        VVK_CHECK_ACT(break, device.handle().CreateSampler(sampler_info, image.sampler));
        return image;
    } while (false);
    /*
    if (result != vk::Result::eSuccess) {
        device.DestroyImageParameters(image);
    }
    */
    return std::nullopt;
}

inline VkResult CopyImageData(std::span<const BufferParameters> in_bufs,
                              std::span<const VkExtent3D> in_exts, const vvk::Queue& queue,
                              vvk::CommandBuffer& cmd, const ImageParameters& image,
                              VkFence fence = VK_NULL_HANDLE) {
    VkResult result;
    do {
        result = cmd.Begin(VkCommandBufferBeginInfo {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = nullptr,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        if (result != VK_SUCCESS) break;

        VkImageSubresourceRange subresourceRange {
            .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel   = 0,
            .levelCount     = (uint32_t)in_bufs.size(),
            .baseArrayLayer = 0,
            .layerCount     = 1,
        };
        {
            VkImageMemoryBarrier in_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = VK_ACCESS_MEMORY_WRITE_BIT,
                .dstAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                VK_PIPELINE_STAGE_TRANSFER_BIT,
                                VK_DEPENDENCY_BY_REGION_BIT,
                                in_bar);
        }
        VkBufferImageCopy copy {
            .imageSubresource =
                VkImageSubresourceLayers {
                    .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .layerCount     = 1,
                },
        };
        for (usize i = 0; i < in_bufs.size(); i++) {
            copy.imageSubresource.mipLevel = (u32)i;
            copy.imageExtent               = in_exts[i];
            cmd.CopyBufferToImage(
                in_bufs[i].handle, image.handle, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, copy);
        }
        {
            VkImageMemoryBarrier out_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
                .dstAccessMask    = VK_ACCESS_SHADER_READ_BIT,
                .oldLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .newLayout        = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                VK_DEPENDENCY_BY_REGION_BIT,
                                out_bar);
        }
        result = cmd.End();
        if (result != VK_SUCCESS) break;

        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = cmd.address(),
        };
        result = queue.Submit(sub_info, fence);
    } while (false);
    return result;
}
} // namespace

VkSampleCountFlagBits vulkan::PlannedTextureSampleCountForGpuAllocation(TextureKey key) {
    if (key.usage != TexUsage::MSAA_COLOR) return VK_SAMPLE_COUNT_1_BIT;
    return key.sample_count;
}

bool TextureCache::ReadbackImageSample(const ImageParameters& image, uint32_t x, uint32_t y,
                                       uint32_t width, uint32_t height,
                                       std::vector<std::uint8_t>* out, std::string* error) {
    if (out == nullptr) {
        return SetError(error, "readback output buffer must not be null");
    }
    if (width == 0 || height == 0) {
        return SetError(error, "readback sample dimensions must be non-zero");
    }
    if (image.handle == VK_NULL_HANDLE) {
        return SetError(error, "readback source image handle must not be null");
    }
    if (x >= image.extent.width || y >= image.extent.height) {
        return SetError(error, "readback sample origin is outside the image extent");
    }

    const uint32_t sample_width  = std::min(width, image.extent.width - x);
    const uint32_t sample_height = std::min(height, image.extent.height - y);
    const size_t   byte_count =
        static_cast<size_t>(sample_width) * static_cast<size_t>(sample_height) * 4u;
    if (byte_count == 0) {
        return SetError(error, "readback sample region resolved to zero bytes");
    }

    VmaBufferParameters readback_buffer;
    if (! CreateReadbackBuffer(m_device.vma_allocator(), byte_count, readback_buffer)) {
        return SetError(error, "failed to allocate a Vulkan readback buffer");
    }

    if (! m_tex_cmd) allocateCmd();

    const VkImageLayout           original_layout = image.layout;
    const VkImageSubresourceRange subresource_range {
        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel   = 0,
        .levelCount     = 1,
        .baseArrayLayer = 0,
        .layerCount     = 1,
    };
    const VkImageMemoryBarrier to_transfer_src {
        .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcAccessMask       = VK_ACCESS_MEMORY_READ_BIT,
        .dstAccessMask       = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout           = original_layout,
        .newLayout           = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image               = image.handle,
        .subresourceRange    = subresource_range,
    };
    const VkImageMemoryBarrier restore_layout {
        .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcAccessMask       = VK_ACCESS_TRANSFER_READ_BIT,
        .dstAccessMask       = VK_ACCESS_MEMORY_READ_BIT,
        .oldLayout           = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .newLayout           = original_layout,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image               = image.handle,
        .subresourceRange    = subresource_range,
    };
    const VkBufferImageCopy copy_region {
        .bufferOffset      = 0,
        .bufferRowLength   = 0,
        .bufferImageHeight = 0,
        .imageSubresource =
            VkImageSubresourceLayers {
                .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel       = 0,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },
        .imageOffset = VkOffset3D { static_cast<int32_t>(x), static_cast<int32_t>(y), 0 },
        .imageExtent = VkExtent3D { sample_width, sample_height, 1 },
    };
    std::array                  copy_regions { copy_region };
    const VkBufferMemoryBarrier host_barrier {
        .sType               = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask       = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer              = *readback_buffer.handle,
        .offset              = 0,
        .size                = byte_count,
    };

    VkResult result = m_tex_cmd.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to begin command buffer for video readback");
    }

    m_tex_cmd.PipelineBarrier(
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, to_transfer_src);
    m_tex_cmd.CopyImageToBuffer(
        image.handle, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, *readback_buffer.handle, copy_regions);
    m_tex_cmd.PipelineBarrier(
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, host_barrier);
    m_tex_cmd.PipelineBarrier(
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, restore_layout);

    result = m_tex_cmd.End();
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to end command buffer for video readback");
    }

    const VkSubmitInfo submit_info {
        .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext              = nullptr,
        .commandBufferCount = 1,
        .pCommandBuffers    = m_tex_cmd.address(),
    };
    std::array submit_infos { submit_info };
    result = m_device.graphics_queue().handle.Submit(submit_infos);
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to submit Vulkan readback command buffer");
    }

    result = m_device.handle().WaitIdle();
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to idle Vulkan device after video readback");
    }

    void* mapped_bytes = nullptr;
    result             = readback_buffer.handle.MapMemory(&mapped_bytes);
    if (result != VK_SUCCESS || mapped_bytes == nullptr) {
        if (result != VK_SUCCESS) VVK_CHECK(result);
        return SetError(error, "failed to map Vulkan readback buffer");
    }

    out->resize(byte_count);
    memcpy(out->data(), mapped_bytes, byte_count);
    readback_buffer.handle.UnMapMemory();
    return true;
}

std::size_t TextureKey::HashValue(const TextureKey& k) {
    std::size_t seed { 0 };
    utils::hash_combine(seed, k.width);
    utils::hash_combine(seed, k.height);
    utils::hash_combine(seed, (int)k.usage);
    utils::hash_combine(seed, (int)k.format);
    utils::hash_combine(seed, (int)k.mipmap_level);
    utils::hash_combine(seed, (int)k.sample_count);

    utils::hash_combine(seed, (int)k.sample.wrapS);
    utils::hash_combine(seed, (int)k.sample.wrapT);
    utils::hash_combine(seed, (int)k.sample.magFilter);
    utils::hash_combine(seed, (int)k.sample.minFilter);
    return seed;
}

std::optional<ExImageParameters> TextureCache::CreateExTex(uint32_t width, uint32_t height,
                                                           VkFormat format, VkImageTiling tiling) {
    VkSamplerCreateInfo sampler_info = GenRenderTargetSamplerInfo();

    auto opt = CreateExImage(width,
                             height,
                             format,
                             tiling,
                             sampler_info,
                             VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                 VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                             m_device.device(),
                             m_device.gpu());
    if (opt.has_value()) {
        const auto& eximg = opt.value();

        if (! m_tex_cmd) allocateCmd();
        TransImgLayout(m_device.graphics_queue().handle, m_tex_cmd, eximg, VK_IMAGE_LAYOUT_GENERAL);
        VVK_CHECK(m_device.handle().WaitIdle());
    }
    return opt;
}

ImageSlotsRef TextureCache::CreateTex(Image& image) {
    return CreateTex(image, TextureUploadSynchronization::Blocking);
}

ImageSlotsRef TextureCache::CreateTex(Image& image, TextureUploadSynchronization synchronization) {
    if (image.header.isVideo) {
        if (exists(m_video_tex_map, image.key)) {
            ImageSlotsRef ref;
            if (auto* current = m_video_tex_map.at(image.key)->current_frame; current != nullptr) {
                ref.slots  = { ImageParameters(current->image) };
                ref.active = 0;
            }
            return ref;
        }

        std::string error;
        auto        source = video::CreateVideoTextureSource(image, &error);
        if (! source) {
            LOG_ERROR("failed to create FFmpeg video texture source for \"%s\": %s",
                      image.key.c_str(),
                      error.c_str());
            return {};
        }
        if (! source->prime(&error)) {
            LOG_ERROR("failed to prime FFmpeg video texture source for \"%s\": %s",
                      image.key.c_str(),
                      error.c_str());
            return {};
        }

        auto video_tex             = std::make_unique<VideoTex>();
        video_tex->sample          = image.header.sample;
        video_tex->source          = std::move(source);
        m_video_tex_map[image.key] = std::move(video_tex);

        ImageSlotsRef ref;
        if (! UpdateVideoFrame(image.key, video::VideoPlaybackState {}, &ref, &error)) {
            LOG_ERROR("failed to import initial video frame for \"%s\": %s",
                      image.key.c_str(),
                      error.c_str());
            m_video_tex_map.erase(image.key);
            return {};
        }
        return ref;
    }

    if (exists(m_tex_map, image.key)) {
        return m_tex_map.at(image.key);
    }

    ImageSlots img_slots;
    bool       submitted_deferred_upload = false;
    auto       fail_texture_upload       = [&]() -> ImageSlotsRef {
        if (submitted_deferred_upload) {
            std::string error;
            if (! waitForPendingTextureUploads(&error) && ! error.empty()) {
                LOG_ERROR(
                    "failed waiting for pending texture upload after texture load failure: %s",
                    error.c_str());
            }
        }
        return {};
    };

    if (synchronization == TextureUploadSynchronization::Blocking && ! m_tex_cmd) allocateCmd();

    img_slots.slots.resize(image.slots.size());

    auto& sam = image.header.sample;

    for (usize i = 0; i < image.slots.size(); i++) {
        auto& image_paras   = img_slots.slots[i];
        auto& image_slot    = image.slots[i];
        auto  mipmap_levels = image_slot.mipmaps.size();

        // check data
        if (! image_slot) return fail_texture_upload();
        VkSamplerCreateInfo sampler_info {
            .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext                   = nullptr,
            .magFilter               = ToVkType(sam.magFilter),
            .minFilter               = (ToVkType(sam.minFilter)),
            .mipmapMode              = VK_SAMPLER_MIPMAP_MODE_LINEAR,
            .addressModeU            = (ToVkType(sam.wrapS)),
            .addressModeV            = (ToVkType(sam.wrapT)),
            .addressModeW            = (ToVkType(sam.wrapT)),
            .anisotropyEnable        = (false),
            .maxAnisotropy           = (1.0f),
            .compareEnable           = (false),
            .compareOp               = VK_COMPARE_OP_NEVER,
            .minLod                  = (0.0f),
            .maxLod                  = (float)mipmap_levels,
            .borderColor             = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = (false),
        };
        VkFormat   format = ToVkType(image.header.format);
        VkExtent3D ext { (u32)image_slot.width, (u32)image_slot.height, 1 };

        if (auto opt = CreateImage(m_device,
                                   ext,
                                   (u32)mipmap_levels,
                                   format,
                                   sampler_info,
                                   VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT);
            opt.has_value()) {
            image_paras = std::move(opt.value());
        } else
            return fail_texture_upload();

        std::vector<VmaBufferParameters> stage_bufs;
        std::vector<VkExtent3D>          extents;

        for (usize j = 0; j < image_slot.mipmaps.size(); j++) {
            auto&               image_data = image_slot.mipmaps[j];
            VmaBufferParameters buf;
            if (image_data.size <= 0) return fail_texture_upload();
            const auto image_data_size = static_cast<std::size_t>(image_data.size);
            if (! CreateStagingBuffer(m_device.vma_allocator(), image_data_size, buf)) {
                return fail_texture_upload();
            }
            {
                void* v_data;
                VVK_CHECK(buf.handle.MapMemory(&v_data));
                memcpy(v_data, image_data.data.get(), image_data_size);
                buf.handle.UnMapMemory();
            }
            stage_bufs.emplace_back(std::move(buf));
            extents.push_back(VkExtent3D { (u32)image_data.width, (u32)image_data.height, 1 });
        }

        if (synchronization == TextureUploadSynchronization::Deferred) {
            std::string error;
            auto*       upload_slot = acquireTextureUploadSubmissionSlot(&error);
            if (upload_slot == nullptr) {
                if (! error.empty()) {
                    LOG_ERROR("failed to acquire texture upload slot for \"%s\": %s",
                              image.key.c_str(),
                              error.c_str());
                }
                return fail_texture_upload();
            }

            const VkResult result =
                CopyImageData(transform<VmaBufferParameters>(stage_bufs,
                                                             [](BufferParameters e) {
                                                                 return e;
                                                             }),
                              extents,
                              m_device.graphics_queue().handle,
                              upload_slot->command,
                              image_paras,
                              *upload_slot->fence);
            if (result != VK_SUCCESS) {
                VVK_CHECK(result);
                return fail_texture_upload();
            }
            upload_slot->staging_buffers  = std::move(stage_bufs);
            upload_slot->pending          = true;
            upload_slot->submitted_serial = ++m_texture_upload_submit_serial;
            submitted_deferred_upload     = true;
        } else {
            const VkResult result =
                CopyImageData(transform<VmaBufferParameters>(stage_bufs,
                                                             [](BufferParameters e) {
                                                                 return e;
                                                             }),
                              extents,
                              m_device.graphics_queue().handle,
                              m_tex_cmd,
                              image_paras);
            if (result != VK_SUCCESS) {
                VVK_CHECK(result);
                return {};
            }

            m_device.handle().WaitIdle();
        }
    }
    m_tex_map[image.key] = std::move(img_slots);
    return m_tex_map[image.key];
}

ImageSlotsRef TextureCache::ReplaceTex(Image& image, std::string_view previous_key) {
    auto replacement = CreateTex(image, TextureUploadSynchronization::Deferred);
    if (! replacement.slots.empty() && ! previous_key.empty() && previous_key != image.key) {
        retireRuntimeTexture(previous_key);
    }
    return replacement;
}

void TextureCache::allocateCmd() {
    const auto& pool = m_device.cmd_pool();
    VVK_CHECK(pool.Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, m_tex_cmds));
    m_tex_cmd = vvk::CommandBuffer(m_tex_cmds[0], m_device.handle().Dispatch());
}

TextureCache::TextureUploadSubmissionSlot*
TextureCache::acquireTextureUploadSubmissionSlot(std::string* error) {
    collectCompletedTextureUploads();
    for (auto& slot : m_texture_upload_slots) {
        if (! slot.pending) return &slot;
    }

    if (m_texture_upload_slots.size() >= kMaxPendingTextureUploads) {
        auto oldest = std::min_element(
            m_texture_upload_slots.begin(),
            m_texture_upload_slots.end(),
            [](const TextureUploadSubmissionSlot& lhs, const TextureUploadSubmissionSlot& rhs) {
                return lhs.submitted_serial < rhs.submitted_serial;
            });
        if (oldest == m_texture_upload_slots.end()) {
            SetError(error, "texture upload submission slot accounting is invalid");
            return nullptr;
        }
        if (! waitForTextureUploadSlot(*oldest, error)) return nullptr;
        return &*oldest;
    }

    TextureUploadSubmissionSlot slot;
    const auto&                 pool = m_device.cmd_pool();
    if (const VkResult result = pool.Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, slot.commands);
        result != VK_SUCCESS) {
        VVK_CHECK(result);
        SetError(error, "failed to allocate texture upload command buffer");
        return nullptr;
    }
    slot.command = vvk::CommandBuffer(slot.commands[0], m_device.handle().Dispatch());

    VkFenceCreateInfo fence_info {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = nullptr,
        .flags = 0,
    };
    if (const VkResult result = m_device.handle().CreateFence(fence_info, slot.fence);
        result != VK_SUCCESS) {
        VVK_CHECK(result);
        SetError(error, "failed to create Vulkan fence for texture upload");
        return nullptr;
    }

    m_texture_upload_slots.emplace_back(std::move(slot));
    return &m_texture_upload_slots.back();
}

bool TextureCache::waitForTextureUploadSlot(TextureUploadSubmissionSlot& slot, std::string* error) {
    if (! slot.pending) return true;

    if (const VkResult result = slot.fence.Wait(); result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed waiting for pending texture upload");
    }
    if (const VkResult result = slot.fence.Reset(); result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed resetting texture upload fence");
    }

    slot.staging_buffers.clear();
    slot.pending          = false;
    slot.submitted_serial = 0;
    return true;
}

bool TextureCache::waitForPendingTextureUploads(std::string* error) {
    for (auto& slot : m_texture_upload_slots) {
        if (! waitForTextureUploadSlot(slot, error)) return false;
    }
    m_retired_runtime_textures.clear();
    return true;
}

void TextureCache::collectCompletedTextureUploads() {
    bool any_pending = false;
    for (auto& slot : m_texture_upload_slots) {
        if (! slot.pending) continue;
        if (slot.fence.GetStatus() != VK_SUCCESS) {
            any_pending = true;
            continue;
        }
        std::string error;
        if (! waitForTextureUploadSlot(slot, &error)) {
            if (! error.empty()) {
                LOG_ERROR("failed collecting completed texture upload: %s", error.c_str());
            }
            any_pending = true;
            continue;
        }
    }
    if (! any_pending) m_retired_runtime_textures.clear();
}

void TextureCache::retireRuntimeTexture(std::string_view key) {
    auto iter = m_tex_map.find(key);
    if (iter == m_tex_map.end()) return;
    m_retired_runtime_textures.emplace_back(std::move(iter->second));
    m_tex_map.erase(iter);
}

void TextureCache::CollectCompletedUploads() { collectCompletedTextureUploads(); }

TextureCache::VideoImportSubmissionSlot*
TextureCache::acquireVideoImportSubmissionSlot(std::string* error) {
    for (auto& slot : m_video_import_slots) {
        if (slot.pending && slot.fence.GetStatus() == VK_SUCCESS) {
            if (! waitForVideoImportSlot(slot, error)) return nullptr;
        }
        if (! slot.pending) return &slot;
    }

    VideoImportSubmissionPlan plan {
        .pending_submissions = m_video_import_slots.size(),
        .available_slots     = kMaxPendingVideoImportSubmissions,
        .must_destroy_resource = false,
    };
    if (VideoImportSubmissionNeedsFenceWait(plan)) {
        auto oldest = std::min_element(m_video_import_slots.begin(),
                                       m_video_import_slots.end(),
                                       [](const VideoImportSubmissionSlot& lhs,
                                          const VideoImportSubmissionSlot& rhs) {
                                           return lhs.submitted_serial < rhs.submitted_serial;
                                       });
        if (oldest == m_video_import_slots.end()) {
            SetError(error, "video import submission slot accounting is invalid");
            return nullptr;
        }
        if (! waitForVideoImportSlot(*oldest, error)) return nullptr;
        return &*oldest;
    }

    VideoImportSubmissionSlot slot;
    const auto&               pool = m_device.cmd_pool();
    if (const VkResult result = pool.Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, slot.commands);
        result != VK_SUCCESS) {
        VVK_CHECK(result);
        SetError(error, "failed to allocate video frame import command buffer");
        return nullptr;
    }
    slot.command = vvk::CommandBuffer(slot.commands[0], m_device.handle().Dispatch());
    ++m_video_submission_stats.command_buffer_allocations;

    VkFenceCreateInfo fence_info {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = nullptr,
        .flags = 0,
    };
    if (const VkResult result = m_device.handle().CreateFence(fence_info, slot.fence);
        result != VK_SUCCESS) {
        VVK_CHECK(result);
        SetError(error, "failed to create Vulkan fence for video frame import");
        return nullptr;
    }
    ++m_video_submission_stats.fence_allocations;

    m_video_import_slots.emplace_back(std::move(slot));
    m_video_submission_stats.import_submission_slots = m_video_import_slots.size();
    return &m_video_import_slots.back();
}

bool TextureCache::waitForVideoImportSlot(VideoImportSubmissionSlot& slot, std::string* error) {
    if (! slot.pending) return true;
    ++m_video_submission_stats.fence_waits;

    if (const VkResult result = slot.fence.Wait(); result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed waiting for pending video frame import");
    }
    if (const VkResult result = slot.fence.Reset(); result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed resetting video frame import fence");
    }

    slot.pending          = false;
    slot.submitted_serial = 0;
    return true;
}

bool TextureCache::waitForPendingVideoImports(std::string* error) {
    for (auto& slot : m_video_import_slots) {
        if (! waitForVideoImportSlot(slot, error)) return false;
    }
    return true;
}

VkSampler TextureCache::GetOrCreateSampler(TextureKey tex_key, std::string* error) {
    const TexHash hash = TextureKey::HashValue(tex_key);
    for (auto& entry : m_sampler_cache) {
        if (entry.hash == hash && entry.sampler) return *entry.sampler;
    }

    CachedSampler entry {};
    entry.hash = hash;
    if (const VkResult result =
            m_device.handle().CreateSampler(GenSamplerInfo(tex_key), entry.sampler);
        result != VK_SUCCESS) {
        VVK_CHECK(result);
        SetError(error, "failed to create cached Vulkan sampler");
        return VK_NULL_HANDLE;
    }
    const VkSampler sampler = *entry.sampler;
    m_sampler_cache.push_back(std::move(entry));
    return sampler;
}

void* TextureCache::GetMetalDeviceHandle(std::string* error) {
    if (m_metal_device != nullptr) return m_metal_device;
    if (m_metal_device_queried) {
        SetError(error, "cached Metal device handle is not available");
        return nullptr;
    }
    m_metal_device         = ExportMetalDeviceHandle(m_device, error);
    m_metal_device_queried = true;
    return m_metal_device;
}

std::optional<VmaImageParameters> TextureCache::CreateTex(TextureKey tex_key) {
    VmaImageParameters image_paras;
    do {
        const VkSampleCountFlagBits planned_samples =
            PlannedTextureSampleCountForGpuAllocation(tex_key);
        VkSamplerCreateInfo sam_info = GenSamplerInfo(tex_key);
        VkFormat            format   = ToVkType(tex_key.format);
        VkExtent3D          ext { (u32)tex_key.width, (u32)tex_key.height, 1 };

        if (auto opt =
                CreateImage(m_device,
                            ext,
                            tex_key.mipmap_level,
                            format,
                            sam_info,
                            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                            VMA_MEMORY_USAGE_GPU_ONLY,
                            planned_samples);
            opt.has_value()) {
            image_paras = std::move(opt.value());
        } else
            break;

        const VkImageLayout final_layout = planned_samples == VK_SAMPLE_COUNT_1_BIT
                                               ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                                               : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        if (! m_tex_cmd) allocateCmd();
        TransImgLayout(m_device.graphics_queue().handle,
                       m_tex_cmd,
                       image_paras,
                       final_layout);
        image_paras.layout = final_layout;

        VVK_CHECK_ACT(break, m_device.handle().WaitIdle());
        return image_paras;
    } while (false);
    return std::nullopt;
}

TextureCache::TextureCache(const Device& device): m_device(device) {}

TextureCache::~TextureCache() {};

void TextureCache::SetVideoPlaybackPaused(bool paused) { m_video_playback_state.paused = paused; }

void TextureCache::SetVideoPlaybackRate(float rate) { m_video_playback_state.rate = rate; }

VideoTextureSubmissionStats TextureCache::VideoSubmissionStats() const {
    auto stats                    = m_video_submission_stats;
    stats.import_submission_slots = m_video_import_slots.size();
    return stats;
}

void TextureCache::ResetVideoSubmissionStats() { m_video_submission_stats = {}; }

double TextureCache::GetVideoDuration(std::string_view key) const {
    const auto iterator = m_video_tex_map.find(std::string(key));
    if (iterator == m_video_tex_map.end() || iterator->second == nullptr ||
        ! iterator->second->source) {
        return 0.0;
    }
    return iterator->second->source->durationSeconds();
}

bool TextureCache::CanReuseVideoFrameImport(const video::VideoTextureFrame& frame) const {
    return frame.io_surface != nullptr && frame.plane_count <= 1;
}

TextureCache::ImportedVideoFrame*
TextureCache::FindImportedVideoFrame(VideoTex& video_tex, const video::VideoTextureFrame& frame,
                                     void* surface_identity) const {
    const bool can_reuse_surface_import = CanReuseVideoFrameImport(frame);
    for (auto& imported_frame : video_tex.imported_frames) {
        if (imported_frame == nullptr) continue;
        if (imported_frame->surface_identity != surface_identity) continue;
        if (imported_frame->pixel_format != frame.pixel_format) continue;
        if (imported_frame->image.extent.width != frame.width ||
            imported_frame->image.extent.height != frame.height) {
            continue;
        }
        if (! can_reuse_surface_import && imported_frame->generation != frame.generation) {
            continue;
        }
        return imported_frame.get();
    }
    return nullptr;
}

bool TextureCache::EnsureVideoFrameCacheRoom(VideoTex& video_tex, std::string* error) {
    while (video_tex.imported_frames.size() >= kMaxImportedVideoFramesPerVideoTex) {
        auto victim = video_tex.imported_frames.end();
        for (auto iter = video_tex.imported_frames.begin(); iter != video_tex.imported_frames.end();
             ++iter) {
            if (iter->get() == video_tex.current_frame) continue;
            if (victim == video_tex.imported_frames.end() ||
                (*iter)->last_used < (*victim)->last_used) {
                victim = iter;
            }
        }
        if (victim == video_tex.imported_frames.end()) return true;
        if (! waitForPendingVideoImports(error)) return false;
        ++m_video_submission_stats.evictions;
        video_tex.imported_frames.erase(victim);
    }
    return true;
}

void TextureCache::Clear() {
    std::string error;
    if (! waitForPendingTextureUploads(&error) && ! error.empty()) {
        LOG_ERROR("failed waiting for pending texture upload before cache clear: %s",
                  error.c_str());
        error.clear();
    }
    if (! waitForPendingVideoImports(&error) && ! error.empty()) {
        LOG_ERROR("failed waiting for pending video import before cache clear: %s", error.c_str());
    }
    m_tex_map.clear();
    m_video_tex_map.clear();
    m_query_texs.clear();
    m_query_map.clear();
}

bool TextureCache::UpdateVideoFrame(std::string_view                 key,
                                    const video::VideoPlaybackState& playback_state,
                                    ImageSlotsRef* out, std::string* error) {
    ++m_video_submission_stats.update_calls;
    if (! exists(m_video_tex_map, key)) {
        return SetError(error, std::string("video texture not registered: ") + std::string(key));
    }

    auto& video_tex = *m_video_tex_map.at(std::string(key));
    if (! video_tex.source) {
        return SetError(error, std::string("video texture source missing: ") + std::string(key));
    }

    const video::VideoPlaybackState effective_state =
        ResolveEffectiveVideoPlaybackState(m_video_playback_state, playback_state);

    if (! video_tex.source->syncPlayback(effective_state, error)) {
        return false;
    }
    if (! video_tex.source->refreshFrame(error)) {
        return false;
    }

    const auto frame = video_tex.source->currentFrame();
    if (! frame.valid()) {
        return SetError(error,
                        std::string("video frame is not ready for texture: ") + std::string(key));
    }

    void* surface_identity = frame.io_surface != nullptr ? frame.io_surface : frame.pixel_buffer;
    if (auto* imported_frame = FindImportedVideoFrame(video_tex, frame, surface_identity);
        imported_frame != nullptr) {
        ++m_video_submission_stats.cache_hits;
        imported_frame->generation = frame.generation;
        imported_frame->last_used  = ++video_tex.frame_use_serial;
        video_tex.current_frame    = imported_frame;
    } else {
        if (! EnsureVideoFrameCacheRoom(video_tex, error)) {
            return false;
        }

        void* metal_device = GetMetalDeviceHandle(error);
        if (metal_device == nullptr) {
            return false;
        }
        void* metal_texture =
            video::CreateAppleVideoMetalTextureForDevice(frame, metal_device, error);
        if (metal_texture == nullptr) {
            return false;
        }

        TextureKey sampler_key {
            .width        = static_cast<i32>(frame.width),
            .height       = static_cast<i32>(frame.height),
            .usage        = TexUsage::COLOR,
            .format       = TextureFormat::RGBA8,
            .sample       = video_tex.sample,
            .mipmap_level = 1,
        };
        const VkSampler sampler = GetOrCreateSampler(sampler_key, error);
        if (sampler == VK_NULL_HANDLE) {
            video::ReleaseAppleVideoMetalTexture(metal_texture);
            return false;
        }

        auto imported_image = CreateImportedMetalTextureImage(
            m_device, metal_texture, video_tex.sample, sampler, frame.width, frame.height, error);
        if (! imported_image.has_value()) {
            video::ReleaseAppleVideoMetalTexture(metal_texture);
            return false;
        }
        auto* submission_slot = acquireVideoImportSubmissionSlot(error);
        if (submission_slot == nullptr) {
            video::ReleaseAppleVideoMetalTexture(metal_texture);
            return false;
        }
        if (const VkResult result = TransImgLayout(m_device.graphics_queue().handle,
                                                   submission_slot->command,
                                                   imported_image.value(),
                                                   imported_image->layout,
                                                   *submission_slot->fence);
            result != VK_SUCCESS) {
            VVK_CHECK(result);
            video::ReleaseAppleVideoMetalTexture(metal_texture);
            return SetError(error, "failed to transition imported video frame image layout");
        }
        submission_slot->pending          = true;
        submission_slot->submitted_serial = ++m_video_import_submit_serial;

        auto new_imported_frame           = std::make_unique<ImportedVideoFrame>();
        new_imported_frame->image         = std::move(imported_image.value());
        new_imported_frame->metal_texture = std::shared_ptr<void>(metal_texture, [](void* handle) {
            video::ReleaseAppleVideoMetalTexture(handle);
        });
        new_imported_frame->generation    = frame.generation;
        new_imported_frame->last_used     = ++video_tex.frame_use_serial;
        new_imported_frame->surface_identity = surface_identity;
        new_imported_frame->pixel_format     = frame.pixel_format;

        video_tex.current_frame = new_imported_frame.get();
        video_tex.imported_frames.emplace_back(std::move(new_imported_frame));
        ++m_video_submission_stats.new_imports;
    }

    if (out != nullptr && video_tex.current_frame != nullptr) {
        out->slots  = { ImageParameters(video_tex.current_frame->image) };
        out->active = 0;
    }

    return true;
}

std::optional<ImageParameters> TextureCache::Query(std::string_view key, TextureKey content_hash,
                                                   bool persist) {
    if (exists(m_query_map, key)) {
        auto& query = *(m_query_map.find(key)->second);

        query.share_ready = false;
        query.persist     = persist;

        return query.image;
    };

    TexHash tex_hash = TextureKey::HashValue(content_hash);
    for (auto& query : m_query_texs) {
        if (! (query->share_ready)) continue;
        if (query->content_hash != tex_hash) continue;

        query->share_ready = false;
        query->persist     = persist;
        query->query_keys.insert(std::string(key));

        m_query_map[std::string(key)] = &(*query);

        return query->image;
    }

    m_query_texs.emplace_back(std::make_unique<QueryTex>());
    auto& query                   = *m_query_texs.back();
    m_query_map[std::string(key)] = &query;

    query.index        = (idx)m_query_texs.size() - 1;
    query.content_hash = tex_hash;
    query.query_keys.insert(std::string(key));
    query.persist = persist;
    if (auto opt = CreateTex(content_hash); opt.has_value()) {
        query.image = std::move(opt.value());
        return query.image;
    }
    return std::nullopt;
}

void TextureCache::MarkShareReady(std::string_view key) {
    if (exists(m_query_map, key)) {
        auto& query = m_query_map.find(key)->second;
        if (query->persist) return;
        query->share_ready = true;
        m_query_map.erase(key.data());
    }
}

void TextureCache::RecGenerateMipmaps(vvk::CommandBuffer& cmd, const ImageParameters& image) const {
    VkImageMemoryBarrier barrier {
        .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image               = image.handle,
        .subresourceRange =
            VkImageSubresourceRange {
                .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel   = 0,
                .levelCount     = 1,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },
    };
    /*
    cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                        VK_DEPENDENCY_BY_REGION_BIT,
                        out_bar);
        */

    i32 mipWidth  = (i32)image.extent.width;
    i32 mipHeight = (i32)image.extent.height;

    for (uint i = 1; i < image.mipmap_level; i++) {
        barrier.subresourceRange.baseMipLevel = i - 1;
        barrier.oldLayout                     = i == 1 ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                                                       : VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;

        barrier.newLayout     = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

        cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                            VK_PIPELINE_STAGE_TRANSFER_BIT,
                            VK_DEPENDENCY_BY_REGION_BIT,
                            barrier);

        barrier.subresourceRange.baseMipLevel = i;
        barrier.oldLayout                     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.newLayout                     = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;

        cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                            VK_PIPELINE_STAGE_TRANSFER_BIT,
                            VK_DEPENDENCY_BY_REGION_BIT,
                            barrier);

        VkImageBlit blit {
            .srcSubresource =
                VkImageSubresourceLayers {
                    .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel       = i - 1,
                    .baseArrayLayer = 0,
                    .layerCount     = 1,
                },
            .srcOffsets = { VkOffset3D { 0, 0, 0 }, VkOffset3D { mipWidth, mipHeight, 1 } },
            .dstOffsets = { VkOffset3D { 0, 0, 0 },
                            VkOffset3D { mipWidth > 1 ? mipWidth / 2 : 1,
                                         mipHeight > 1 ? mipHeight / 2 : 1,
                                         1 } },
        };
        blit.dstSubresource =
            VkImageSubresourceLayers {
                .aspectMask     = blit.srcSubresource.aspectMask,
                .mipLevel       = blit.srcSubresource.mipLevel + 1,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },

        cmd.BlitImage(image.handle,
                      VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                      image.handle,
                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                      blit,
                      VK_FILTER_LINEAR);

        barrier.subresourceRange.baseMipLevel = i - 1;
        barrier.oldLayout                     = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout                     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask                 = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask                 = VK_ACCESS_SHADER_READ_BIT;

        cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                            VK_DEPENDENCY_BY_REGION_BIT,
                            barrier);

        if (mipWidth > 1) mipWidth /= 2;
        if (mipHeight > 1) mipHeight /= 2;
    }

    barrier.subresourceRange.baseMipLevel = image.mipmap_level - 1;
    barrier.oldLayout                     = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout                     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask                 = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask                 = VK_ACCESS_SHADER_READ_BIT;

    cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                        VK_DEPENDENCY_BY_REGION_BIT,
                        barrier);
}
