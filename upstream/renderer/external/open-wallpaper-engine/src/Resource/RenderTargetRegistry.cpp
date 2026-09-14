#include "Resource/RenderTargetRegistry.hpp"

#include "SpecTexs.hpp"

#include <algorithm>

namespace wallpaper
{

namespace
{

int scaled(int value, int divisor)
{
    return std::max(1, value / divisor);
}

SceneRenderTarget makeRenderTarget(int width, int height, bool allow_reuse = false)
{
    return SceneRenderTarget {
        .width = width,
        .height = height,
        .allowReuse = allow_reuse,
    };
}

} // namespace

RenderTargetRegistry::RenderTargetRegistry(
    std::unordered_map<std::string, SceneRenderTarget>& targets,
    std::unordered_map<std::string, std::string>& aliases)
    : m_targets(&targets),
      m_aliases(&aliases)
{
}

RenderTargetRegistry::RenderTargetRegistry(
    const std::unordered_map<std::string, SceneRenderTarget>& targets,
    const std::unordered_map<std::string, std::string>& aliases)
    : m_owned_targets(targets),
      m_owned_aliases(aliases)
{
}

void RenderTargetRegistry::installBuiltIns(int width, int height)
{
    (*m_targets)[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = width,
        .height = height,
        .bind = { .enable = true, .screen = true },
    };

    insert("_rt_FullFrameBuffer", makeRenderTarget(width, height));
    insert(
        std::string(WE_MIP_MAPPED_FRAME_BUFFER),
        SceneRenderTarget {
            .width = width,
            .height = height,
            .has_mipmap = true,
            .bind = { .enable = true, .name = std::string(SpecTex_Default) },
        });

    insert("_rt_shadowAtlas", makeRenderTarget(width, height, true));
    insert("_rt_ParticleRefract", makeRenderTarget(width, height, true));
    insert("_rt_4FrameBuffer", makeRenderTarget(scaled(width, 4), scaled(height, 4), true));
    insert("_rt_8FrameBuffer", makeRenderTarget(scaled(width, 8), scaled(height, 8), true));
    insert("_rt_Bloom", makeRenderTarget(scaled(width, 8), scaled(height, 8), true));
}

void RenderTargetRegistry::insert(std::string name, SceneRenderTarget target)
{
    (*m_targets)[std::move(name)] = std::move(target);
}

void RenderTargetRegistry::alias(std::string alias_name, std::string target_name)
{
    (*m_aliases)[std::move(alias_name)] = std::move(target_name);
}

bool RenderTargetRegistry::contains(std::string_view name) const
{
    return lookup(name) != nullptr;
}

std::string RenderTargetRegistry::resolve(std::string_view name) const
{
    auto it = m_aliases->find(std::string(name));
    if (it != m_aliases->end()) return it->second;
    return std::string(name);
}

const SceneRenderTarget* RenderTargetRegistry::lookup(std::string_view name) const
{
    const std::string resolved = resolve(name);
    auto it = m_targets->find(resolved);
    if (it == m_targets->end()) return nullptr;
    return &it->second;
}

} // namespace wallpaper
