#include "Scene.h"

#include "Fs/VFS.h"
#include "Interface/IImageParser.h"
#include "Interface/IShaderValueUpdater.h"
#include "Particle/ParticleSystem.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Utils/Algorism.h"

namespace wallpaper 
{

Scene::Scene(): sceneGraph(std::make_shared<SceneNode>()) ,paritileSys(std::make_unique<ParticleSystem>(*this)) {}
Scene::~Scene() = default;

void Scene::FrameCanvas(double zoom, const Eigen::Vector2f& offset) {
    const auto global = cameras.find("global");
    if (global == cameras.end() || global->second == nullptr) return;
    auto& camera = *global->second;

    const Eigen::Vector2f centre = Eigen::Vector2f(static_cast<float>(ortho[0]),
                                                   static_cast<float>(ortho[1])) * 0.5f + offset;
    // Only the view's centre moves; each camera keeps its own distance from
    // the canvas plane.
    const auto aim = [&centre](SceneCamera& target) {
        const auto node = target.GetAttachedNode();
        if (node == nullptr) return;
        Eigen::Vector3f translate = node->Translate();
        translate.head<2>()       = centre;
        node->SetTranslate(translate);
    };
    camera.SetZoom(zoom);
    aim(camera);
    camera.Update();
    if (const auto perspective = cameras.find("global_perspective");
        perspective != cameras.end() && perspective->second != nullptr) {
        auto& perspective_camera = *perspective->second;
        aim(perspective_camera);
        if (! perspective_camera.FovLocked()) {
            perspective_camera.SetFov(
                algorism::CalculatePersperctiveFov(1000.0, camera.VisibleHeight()));
        }
        perspective_camera.Update();
    }
    UpdateLinkedCamera("global");
}

}

