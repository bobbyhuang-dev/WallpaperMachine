#pragma once
#include "VulkanPass.hpp"
#include <string>

#include "Vulkan/Device.hpp"
#include "Scene/Scene.h"
#include "VulkanRender/CopyElision.hpp"

namespace wallpaper
{
namespace vulkan
{

class CopyPass : public VulkanPass {
public:
    struct Desc {
        std::string src;
        std::string dst;

        /// Decided once the whole pass list is known. `Dead` and `Alias` both
        /// stop the copy from executing; `Alias` additionally points the
        /// destination key at the source's allocation so its readers still see
        /// the pixels the copy would have produced.
        CopyElision elision { CopyElision::None };

        ImageParameters vk_src;
        ImageParameters vk_dst;
    };

    CopyPass(const Desc&);
    virtual ~CopyPass();

    Desc&       desc() { return m_desc; }
    const Desc& desc() const { return m_desc; }

    /// Compile-time shape of this copy for the elision analysis.
    ElisionPassDesc elisionDesc(const Scene&) const;

    void prepare(Scene&, const Device&, RenderingResources&) override;
    VkResult execute(const Device&, RenderingResources&) override;
    void destory(const Device&, RenderingResources&) override;

private:
    Desc m_desc;
};

}
}
