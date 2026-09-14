#pragma once

#ifndef VK_NO_PROTOTYPES
#    define VK_NO_PROTOTYPES
#endif
#include <vulkan/vulkan.h>

#include <cstdint>
#include <array>

namespace wallpaper
{
namespace vulkan
{

inline std::uint32_t SampleCountValue(VkSampleCountFlagBits samples) {
    switch (samples) {
    case VK_SAMPLE_COUNT_64_BIT: return 64;
    case VK_SAMPLE_COUNT_32_BIT: return 32;
    case VK_SAMPLE_COUNT_16_BIT: return 16;
    case VK_SAMPLE_COUNT_8_BIT: return 8;
    case VK_SAMPLE_COUNT_4_BIT: return 4;
    case VK_SAMPLE_COUNT_2_BIT: return 2;
    case VK_SAMPLE_COUNT_1_BIT:
    default: return 1;
    }
}

inline VkSampleCountFlagBits SampleCountFromValue(std::uint32_t samples) {
    switch (samples) {
    case 64: return VK_SAMPLE_COUNT_64_BIT;
    case 32: return VK_SAMPLE_COUNT_32_BIT;
    case 16: return VK_SAMPLE_COUNT_16_BIT;
    case 8: return VK_SAMPLE_COUNT_8_BIT;
    case 4: return VK_SAMPLE_COUNT_4_BIT;
    case 2: return VK_SAMPLE_COUNT_2_BIT;
    case 1:
    default: return VK_SAMPLE_COUNT_1_BIT;
    }
}

inline VkSampleCountFlagBits ResolveSampleCount(std::uint32_t requested,
                                                VkSampleCountFlags supported) {
    if (requested <= 1) return VK_SAMPLE_COUNT_1_BIT;

    constexpr std::array<VkSampleCountFlagBits, 7> descending_sample_counts {
        VK_SAMPLE_COUNT_64_BIT,
        VK_SAMPLE_COUNT_32_BIT,
        VK_SAMPLE_COUNT_16_BIT,
        VK_SAMPLE_COUNT_8_BIT,
        VK_SAMPLE_COUNT_4_BIT,
        VK_SAMPLE_COUNT_2_BIT,
        VK_SAMPLE_COUNT_1_BIT,
    };

    for (const auto sample_count : descending_sample_counts) {
        if (SampleCountValue(sample_count) > requested) continue;
        if ((supported & sample_count) != 0) return sample_count;
    }

    return VK_SAMPLE_COUNT_1_BIT;
}

} // namespace vulkan
} // namespace wallpaper
