#include "Device.hpp"

#include "Utils/Logging.h"
#include "GraphicsPipeline.hpp"

#include <filesystem>
#include <fstream>
#include <vector>

using namespace wallpaper::vulkan;

namespace
{

void EnumateDeviceExts(const vvk::PhysicalDevice& gpu, wallpaper::Set<std::string>& set) {
    std::vector<VkExtensionProperties> properties;
    VVK_CHECK_VOID_RE(gpu.EnumerateDeviceExtensionProperties(properties));
    for (auto& ext : properties) {
        set.insert(ext.extensionName);
    }
}

} // namespace

bool Device::CheckGPU(vvk::PhysicalDevice gpu, std::span<const Extension> exts, VkSurfaceKHR surface) {
    std::vector<VkDeviceQueueCreateInfo> queues;
    auto                                 props = gpu.GetQueueFamilyProperties();

    // check queue
    bool has_graphics_queue { false };
    bool has_present_queue { false };
    uint index { 0 };
    for (auto& prop : props) {
        if (prop.queueFlags & VK_QUEUE_GRAPHICS_BIT) has_graphics_queue = true;
        if (surface) {
            bool ok { false };
            VVK_CHECK(gpu.GetSurfaceSupportKHR(index, surface, ok));
            if (ok) has_present_queue = true;
        }
        index++;
    };
    if (! has_graphics_queue) return false;
    if (surface && ! has_present_queue) return false;

    // check exts
    Set<std::string> extensions;
    EnumateDeviceExts(gpu, extensions);
    for (auto& ext : exts) {
        if (ext.required) {
            if (! exists(extensions, ext.name)) return false;
        }
    }
    return true;
}

std::vector<VkDeviceQueueCreateInfo> Device::ChooseDeviceQueue(VkSurfaceKHR surface) {
    std::vector<VkDeviceQueueCreateInfo> queues;

    auto props = m_gpu.GetQueueFamilyProperties();

    std::vector<uint32_t> graphic_indexs, present_indexs;
    uint32_t              index = 0;
    for (auto& prop : props) {
        if (prop.queueFlags & VK_QUEUE_GRAPHICS_BIT) graphic_indexs.push_back(index);
        index++;
    };
    m_graphics_queue.family_index           = graphic_indexs.front();
    const static float defaultQueuePriority = 0.0f;
    {
        VkDeviceQueueCreateInfo info {
            .sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = m_graphics_queue.family_index,
            .queueCount       = 1,
            .pQueuePriorities = &defaultQueuePriority,
        };
        queues.push_back(info);
    }
    m_present_queue.family_index = graphic_indexs.front();
    if (surface) {
        index = 0;
        for (auto& prop : props) {
            bool ok { false };
            VVK_CHECK(m_gpu.GetSurfaceSupportKHR(index, surface, ok))
            if (ok) present_indexs.push_back(index);
            index++;
        };
        if (present_indexs.empty()) {
            LOG_ERROR("not find present queue");
        } else if (graphic_indexs.front() != present_indexs.front()) {
            m_present_queue.family_index = present_indexs.front();
            VkDeviceQueueCreateInfo info {
                .sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = m_present_queue.family_index,
                .queueCount       = 1,
                .pQueuePriorities = &defaultQueuePriority,
            };
            queues.push_back(info);
        }
    }
    return queues;
}

bool Device::Create(Instance& inst, std::span<const Extension> exts, VkExtent2D extent, Device& device) {
    device.dld      = vvk::DeviceDispatch { inst.inst().Dispatch() };
    device.m_gpu    = inst.gpu();
    device.m_limits = inst.gpu().GetProperties().limits;
    device.set_out_extent(extent);

    Set<std::string> tested_exts;
    {
        EnumateDeviceExts(inst.gpu(), device.m_extensions);
        for (auto& ext : exts) {
            bool ok = device.supportExt(ext.name);
            if (ok) tested_exts.insert(std::string(ext.name));
            if (ext.required && ! ok) {
                LOG_ERROR("required vulkan device extension \"%s\" is not supported",
                          ext.name.data());
                return false;
            }
        }
#if defined(__APPLE__)
        if (device.supportExt("VK_KHR_portability_subset")) {
            tested_exts.insert("VK_KHR_portability_subset");
        }
#endif
    }
    std::vector<const char*> tested_exts_c { tested_exts.size() };
    std::transform(
        tested_exts.begin(), tested_exts.end(), tested_exts_c.begin(), [](const auto& s) {
            return s.c_str();
        });
    bool rq_surface = ! inst.offscreen();
    VVK_CHECK_BOOL_RE(vvk::Device::Create(device.m_device,
                                          *device.m_gpu,
                                          device.ChooseDeviceQueue(*inst.surface()),
                                          tested_exts_c,
                                          nullptr,
                                          device.dld));

    // VK_CHECK_RESULT_BOOL_RE(CreateDevice(inst, device.ChooseDeviceQueue(inst.surface()),
    // tested_exts_c, &device.m_device));

    device.m_graphics_queue.handle = device.m_device.GetQueue(device.m_graphics_queue.family_index);
    device.m_present_queue.handle  = device.m_device.GetQueue(device.m_present_queue.family_index);

    if (rq_surface) {
        if (! Swapchain::Create(device, *inst.surface(), extent, device.m_swapchain)) {
            LOG_ERROR("create swapchain failed");
            return false;
        }
    }
    {
        VkCommandPoolCreateInfo info { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                       .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT |
                                                VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                                       .queueFamilyIndex = device.m_graphics_queue.family_index };
        VVK_CHECK_BOOL_RE(device.m_device.CreateCommandPool(info, device.m_command_pool));
    }
    {
        VmaAllocatorCreateInfo allocatorInfo = {};
        allocatorInfo.vulkanApiVersion       = WP_VULKAN_VERSION;
        allocatorInfo.physicalDevice         = *device.m_gpu;
        allocatorInfo.device                 = *device.m_device;
        allocatorInfo.instance               = *inst.inst();
        VVK_CHECK_BOOL_RE(vvk::CreateVmaAllocator(allocatorInfo, device.m_allocator));
    }
    device.m_tex_cache = std::make_unique<TextureCache>(device);
    device.UsePipelineCacheFile({});
    return true;
}

VkDeviceSize Device::GetUsage() const {
    VmaBudget budget;
    vmaGetHeapBudgets(*m_allocator, &budget);
    return budget.usage;
}

void Device::Destroy() {
    SavePipelineCache();
    destroyPipelineCache();
    VVK_CHECK(m_device.WaitIdle());
}

void Device::releaseSwapchain() { m_swapchain.Destroy(); }

bool Device::recreateSwapchain(VkSurfaceKHR surface, VkExtent2D extent) {
    m_swapchain.Destroy();
    m_extent = extent;
    return Swapchain::Create(*this, surface, extent, m_swapchain);
}

Device::Device(): m_tex_cache(std::make_unique<TextureCache>(*this)) {}
Device::~Device() { destroyPipelineCache(); }

bool Device::supportExt(std::string_view name) const { return exists(m_extensions, name); }

void Device::destroyPipelineCache() {
    if (m_pipeline_cache == VK_NULL_HANDLE || *m_device == VK_NULL_HANDLE) return;
    const auto& dispatch = m_device.Dispatch();
    if (dispatch.vkDestroyPipelineCache != nullptr) {
        dispatch.vkDestroyPipelineCache(*m_device, m_pipeline_cache, nullptr);
    }
    m_pipeline_cache = VK_NULL_HANDLE;
}

void Device::UsePipelineCacheFile(std::string directory) {
    destroyPipelineCache();
    m_pipeline_cache_path.clear();
    if (*m_device == VK_NULL_HANDLE || m_device.Dispatch().vkCreatePipelineCache == nullptr) return;

    std::vector<char> initial;
    if (! directory.empty()) {
        m_pipeline_cache_path = directory + "/vk-pipeline-cache.bin";
        std::ifstream file(m_pipeline_cache_path, std::ios::binary);
        if (file) {
            file.seekg(0, std::ios::end);
            const auto size = file.tellg();
            // A driver blob for one scene. Anything larger is not a cache we wrote.
            if (size > 0 && size < 64 * 1024 * 1024) {
                initial.resize(static_cast<std::size_t>(size));
                file.seekg(0);
                file.read(initial.data(), static_cast<std::streamsize>(initial.size()));
                if (! file) initial.clear();
            }
        }
    }

    auto create = [&](const void* data, std::size_t size) {
        VkPipelineCacheCreateInfo info {
            .sType           = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
            .pNext           = nullptr,
            .flags           = 0,
            .initialDataSize = size,
            .pInitialData    = data,
        };
        return m_device.Dispatch().vkCreatePipelineCache(
            *m_device, &info, nullptr, &m_pipeline_cache);
    };
    VkResult result = create(initial.empty() ? nullptr : initial.data(), initial.size());
    if (result != VK_SUCCESS && ! initial.empty()) {
        m_pipeline_cache = VK_NULL_HANDLE;
        result           = create(nullptr, 0);
    }
    if (result != VK_SUCCESS) {
        m_pipeline_cache = VK_NULL_HANDLE;
        LOG_ERROR("pipeline cache was not created");
    }
}

void Device::SavePipelineCache() const {
    if (m_pipeline_cache == VK_NULL_HANDLE || m_pipeline_cache_path.empty() ||
        *m_device == VK_NULL_HANDLE) {
        return;
    }
    const auto& dispatch = m_device.Dispatch();
    if (dispatch.vkGetPipelineCacheData == nullptr) return;
    std::size_t size = 0;
    if (dispatch.vkGetPipelineCacheData(*m_device, m_pipeline_cache, &size, nullptr) != VK_SUCCESS ||
        size == 0) {
        return;
    }
    std::vector<char> data(size);
    if (dispatch.vkGetPipelineCacheData(*m_device, m_pipeline_cache, &size, data.data()) !=
        VK_SUCCESS) {
        return;
    }
    data.resize(size);
    const auto temporary = m_pipeline_cache_path + ".tmp";
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (! file) return;
        file.write(data.data(), static_cast<std::streamsize>(data.size()));
        if (! file) return;
    }
    std::error_code error;
    std::filesystem::rename(temporary, m_pipeline_cache_path, error);
    if (error) std::filesystem::remove(temporary);
}
