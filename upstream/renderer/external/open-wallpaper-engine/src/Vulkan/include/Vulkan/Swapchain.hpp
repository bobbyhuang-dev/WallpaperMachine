#pragma once
#include "Instance.hpp"
#include <span>

namespace wallpaper
{
namespace vulkan
{
struct ImageParameters;
struct VmaImageParameters;

class Device;
class Swapchain {
public:
    static bool                      Create(Device&, VkSurfaceKHR, VkExtent2D, Swapchain&);
    void                             Destroy();
    const vvk::SwapchainKHR&         handle() const;
    VkFormat                         format() const;
    VkExtent2D                       extent() const;
    VkPresentModeKHR                 presentMode() const;
    std::span<const ImageParameters> images() const;
    bool supportsReadback() const { return m_supports_readback; }

private:
    bool                         m_supports_readback { false };
    vvk::SwapchainKHR            m_handle;
    VkSurfaceFormatKHR           m_format;
    VkExtent2D                   m_extent;
    VkPresentModeKHR             m_present_mode;
    std::vector<ImageParameters> m_images;
    std::vector<vvk::ImageView>  m_imageviews;
};
} // namespace vulkan
} // namespace wallpaper
