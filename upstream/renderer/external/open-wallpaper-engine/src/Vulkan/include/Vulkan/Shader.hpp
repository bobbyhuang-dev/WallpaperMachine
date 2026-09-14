#pragma once
#include "Instance.hpp"
#include "ShaderComp.hpp"

namespace wallpaper
{
namespace vulkan
{

struct ShaderReflected {
    struct BlockedUniform {
        int    block_index;
        uint   offset;
        size_t size { 0 };
        size_t num { 1 }; // for array,vector,matrix
        size_t array_count { 0 };
        size_t array_stride { 0 };
    };
    struct Block {
        int         index;
        uint        size;
        uint        binding { 0 };
        std::string name;

        Map<std::string, BlockedUniform> member_map;
    };
    std::vector<Block> blocks;

    Map<std::string, VkDescriptorSetLayoutBinding> binding_map;

    struct Input {
        uint     location;
        VkFormat format;
    };
    Map<std::string, Input> input_location_map;
};

bool GenReflect(std::span<const std::vector<uint>> codes, std::vector<Uni_ShaderSpv>& spvs,
                ShaderReflected& ref);
} // namespace vulkan
} // namespace wallpaper
