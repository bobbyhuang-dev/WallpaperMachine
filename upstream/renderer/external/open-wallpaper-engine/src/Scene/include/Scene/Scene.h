#pragma once
#include <memory>
#include <string>
#include <unordered_map>
#include <string_view>
#include <variant>
#include <vector>

#include "SceneTexture.h"
#include "SceneRenderTarget.h"
#include "SceneNode.h"
#include "SceneLight.hpp"

#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
class ParticleSystem;
class IShaderValueUpdater;
class IImageParser;
class SceneRuntimeContext;

struct ScenePostProcessPass {
    std::shared_ptr<SceneNode> node;
    std::string                output;
};

struct ScenePostProcessCopy {
    std::string src;
    std::string dst;
};

struct ScenePostProcess {
    using Step = std::variant<ScenePostProcessPass, ScenePostProcessCopy>;

    std::string       name;
    std::vector<Step> steps;
};

namespace fs
{
class VFS;
}
class Scene : NoCopy, NoMove {
public:
    Scene();
    ~Scene();

    std::unordered_map<std::string, SceneTexture>      textures;
    std::unordered_map<std::string, SceneRenderTarget> renderTargets;
    std::unordered_map<std::string, std::string>       renderTargetAliases;

    std::unordered_map<std::string, std::shared_ptr<SceneCamera>> cameras;
    std::unordered_map<std::string, std::vector<std::string>>     linkedCameras;

    std::vector<std::unique_ptr<SceneLight>> lights;

    std::shared_ptr<SceneNode>           sceneGraph;
    std::vector<std::shared_ptr<ScenePostProcess>> post_processes;
    std::unique_ptr<IShaderValueUpdater> shaderValueUpdater;
    std::unique_ptr<IImageParser>        imageParser;
    std::unique_ptr<SceneRuntimeContext> runtime;
    std::unique_ptr<fs::VFS>             vfs;

    std::string scene_id { "unknown_id" };

    bool                 first_frame_ok { false };
    std::array<float, 2> pointerPosition { 0.5f, 0.5f };

    SceneMesh default_effect_mesh;

    std::unique_ptr<ParticleSystem> paritileSys;

    SceneCamera* activeCamera;

    i32                  ortho[2] { 1920, 1080 }; // w, h
    std::array<float, 3> clearColor { 1.0f, 1.0f, 1.0f };
    bool                 clearEnabled { true };

    double elapsingTime { 0.0f }, frameTime { 0.0f };
    void   PassFrameTime(double t) {
        frameTime = t;
        elapsingTime += t;
    }

    void UpdateLinkedCamera(const std::string& name) {
        if (linkedCameras.count(name) != 0) {
            auto& cams = linkedCameras.at(name);
            for (auto& cam : cams) {
                if (cameras.count(cam) != 0) {
                    cameras.at(cam)->Clone(*cameras.at(name));
                    cameras.at(cam)->Update();
                }
            }
        }
    }

    std::string ResolveRenderTargetName(std::string_view name) const {
        auto alias = renderTargetAliases.find(std::string(name));
        if (alias != renderTargetAliases.end()) return alias->second;
        return std::string(name);
    }

    bool HasRenderTarget(std::string_view name) const { return FindRenderTarget(name) != nullptr; }

    SceneRenderTarget* FindRenderTarget(std::string_view name) {
        const std::string resolved = ResolveRenderTargetName(name);
        auto              it       = renderTargets.find(resolved);
        if (it == renderTargets.end()) return nullptr;
        return &it->second;
    }

    const SceneRenderTarget* FindRenderTarget(std::string_view name) const {
        const std::string resolved = ResolveRenderTargetName(name);
        auto              it       = renderTargets.find(resolved);
        if (it == renderTargets.end()) return nullptr;
        return &it->second;
    }
};
} // namespace wallpaper
