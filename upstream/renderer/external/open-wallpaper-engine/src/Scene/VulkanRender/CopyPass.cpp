#include "CopyPass.hpp"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"
#include "Utils/AutoDeletor.hpp"
#include "Resource.hpp"
#include "PassCommon.hpp"

using namespace wallpaper::vulkan;

CopyPass::CopyPass(const Desc& desc): m_desc(desc) {}

CopyPass::~CopyPass() {};

ElisionPassDesc CopyPass::elisionDesc(const Scene& scene) const {
    ElisionPassDesc desc;
    desc.kind   = ElisionPassDesc::Kind::Copy;
    desc.writes = scene.ResolveRenderTargetName(m_desc.dst);
    desc.reads  = { scene.ResolveRenderTargetName(m_desc.src) };

    const auto* src_rt = scene.FindRenderTarget(desc.reads.front());
    const auto* dst_rt = scene.FindRenderTarget(desc.writes);
    if (src_rt != nullptr && dst_rt != nullptr) {
        // Comparing the texture keys is the same equivalence the render-target
        // pool uses when it hands one allocation to another name, so a pair
        // that passes here is a pair the pool would already treat as
        // interchangeable: extent, usage, format, sampling and mip count.
        desc.copy_compatible = TextureKey::HashValue(ToTexKey(*src_rt)) ==
                               TextureKey::HashValue(ToTexKey(*dst_rt));
        desc.copy_generates_mipmaps = dst_rt->mipmap_level > 1;
    }
    return desc;
}

void CopyPass::prepare(Scene& scene, const Device& device, RenderingResources& rr) {
    setPrepared(false);
    const std::string src_name = scene.ResolveRenderTargetName(m_desc.src);
    const std::string dst_name = scene.ResolveRenderTargetName(m_desc.dst);
    if (!scene.HasRenderTarget(src_name)) {
        LOG_ERROR("%s not found", m_desc.src.c_str());
        return;
    }
    if (m_desc.elision == CopyElision::Dead) {
        // Nothing reads the destination, so neither the copy nor an allocation
        // for its result is needed.
        for (auto& tex : releaseTexs()) device.tex_cache().MarkShareReady(tex);
        setPrepared();
        return;
    }
    if (!scene.HasRenderTarget(dst_name)) {
        auto& rt                            = *scene.FindRenderTarget(src_name);
        scene.renderTargets[dst_name]       = rt;
        scene.renderTargets[dst_name].allowReuse = true;
    }

    if (m_desc.elision == CopyElision::Alias) {
        auto& src_rt = *scene.FindRenderTarget(src_name);
        auto  opt    = device.tex_cache().Query(src_name, ToTexKey(src_rt), true);
        if (! opt.has_value()) {
            LOG_ERROR("query image from cache failed");
            return;
        }
        if (! device.tex_cache().AliasRenderTarget(dst_name, src_name)) {
            LOG_ERROR("cannot alias %s onto %s", dst_name.c_str(), src_name.c_str());
            return;
        }
        m_desc.vk_src = opt.value();
        m_desc.vk_dst = opt.value();
        // Both names are pinned by the alias, so releasing either would let the
        // pool hand the image to a third key while these two still read it.
        setPrepared();
        return;
    }

    std::array<std::string, 2>      textures    = { src_name, dst_name };
    std::array<ImageParameters*, 2> vk_textures = { &m_desc.vk_src, &m_desc.vk_dst };
    for (usize i = 0; i < textures.size(); i++) {
        auto& tex_name = textures[i];
        if (tex_name.empty()) continue;

        ImageParameters img {};
        if (IsSpecTex(tex_name)) {
            auto& rt  = *scene.FindRenderTarget(tex_name);
            auto  opt = device.tex_cache().Query(tex_name, ToTexKey(rt), ! rt.allowReuse);
            if (opt.has_value()) {
                img = opt.value();
            } else {
                LOG_ERROR("query image from cache failed");
                return;
            }
        } else {
            LOG_ERROR("can't copy image source");
            return;
        }
        *vk_textures[i] = img;
    }

    for (auto& tex : releaseTexs()) {
        device.tex_cache().MarkShareReady(tex);
    }

    setPrepared();
};
VkResult CopyPass::execute(const Device& device, RenderingResources& rr) {
    if (m_desc.elision != CopyElision::None) return VK_SUCCESS;
    auto& cmd = rr.command;
    auto& src = m_desc.vk_src;
    auto& dst = m_desc.vk_dst;

    if (! (src.handle && dst.handle)) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkImageSubresourceRange srang {
        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel   = 0,
        .levelCount     = 1,
        .baseArrayLayer = 0,
        .layerCount     = 1,

    };
    VkImageCopy copy {
        .srcSubresource =
            VkImageSubresourceLayers {
                .aspectMask     = srang.aspectMask,
                .mipLevel       = 0,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },
        .dstSubresource =
            VkImageSubresourceLayers {
                .aspectMask     = srang.aspectMask,
                .mipLevel       = 0,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },
        .extent = { src.extent.width, src.extent.height, 1 },
    };
    {
        VkImageMemoryBarrier in_bar {
            .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext            = nullptr,
            .srcAccessMask    = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                                VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT,
            .dstAccessMask    = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout        = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .newLayout        = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image            = src.handle,
            .subresourceRange = srang,
        };
        VkImageMemoryBarrier out_bar {
            .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext            = nullptr,
            .srcAccessMask    = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                                VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT,
            .dstAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image            = dst.handle,
            .subresourceRange = srang,
        };

        cmd.PipelineBarrier(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                                VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT |
                                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                            VK_PIPELINE_STAGE_TRANSFER_BIT,
                            0,
                            {},
                            {},
                            std::array { in_bar, out_bar });
    }
    cmd.CopyImage(src.handle,
                  VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                  dst.handle,
                  VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                  copy);
    {
        VkImageMemoryBarrier in_bar {
            .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext            = nullptr,
            .srcAccessMask    = VK_ACCESS_TRANSFER_READ_BIT,
            .dstAccessMask    = VK_ACCESS_SHADER_READ_BIT,
            .oldLayout        = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout        = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image            = src.handle,
            .subresourceRange = srang,
        };
        VkImageMemoryBarrier out_bar {
            .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext            = nullptr,
            .srcAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask    = VK_ACCESS_SHADER_READ_BIT,
            .oldLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout        = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image            = dst.handle,
            .subresourceRange = srang,
        };

        cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                            VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                            0,
                            {},
                            {},
                            std::array { in_bar, out_bar });
    }

    if (dst.mipmap_level > 1) {
        device.tex_cache().RecGenerateMipmaps(cmd, dst);
    }
    return VK_SUCCESS;
};
void CopyPass::destory(const Device&, RenderingResources&) {}
