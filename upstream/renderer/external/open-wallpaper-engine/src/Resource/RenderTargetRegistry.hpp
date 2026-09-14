#pragma once

#include "Scene/include/Scene/SceneRenderTarget.h"

#include <string>
#include <string_view>
#include <unordered_map>

namespace wallpaper
{

class RenderTargetRegistry
{
public:
    RenderTargetRegistry() = default;
    RenderTargetRegistry(
        std::unordered_map<std::string, SceneRenderTarget>& targets,
        std::unordered_map<std::string, std::string>& aliases);
    RenderTargetRegistry(
        const std::unordered_map<std::string, SceneRenderTarget>& targets,
        const std::unordered_map<std::string, std::string>& aliases);

    void installBuiltIns(int width, int height);
    void insert(std::string name, SceneRenderTarget target);
    void alias(std::string alias_name, std::string target_name);
    bool contains(std::string_view name) const;
    std::string resolve(std::string_view name) const;
    const SceneRenderTarget* lookup(std::string_view name) const;

private:
    using TargetMap = std::unordered_map<std::string, SceneRenderTarget>;
    using AliasMap = std::unordered_map<std::string, std::string>;

    TargetMap m_owned_targets;
    AliasMap m_owned_aliases;
    TargetMap* m_targets { &m_owned_targets };
    AliasMap* m_aliases { &m_owned_aliases };
};

} // namespace wallpaper
