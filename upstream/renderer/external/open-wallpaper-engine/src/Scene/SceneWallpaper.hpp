#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include "Type.hpp"
#include "Scene/include/Scene/SceneBackendSelection.hpp"
#include "Scene/include/Scene/SceneVideoPath.hpp"
#include "Scene/include/Scene/SceneUpdateDemand.hpp"
#include "Swapchain/ExSwapchain.hpp"

#if defined(WESCENE_BUILD_TESTS) && defined(__APPLE__)
struct owe_scene_wallpaper;
#endif

namespace wallpaper
{

using FirstFrameCallback = std::function<void()>;
using PointerInputCallback = std::function<void(bool)>;
/// Reports one `engine.openUserShortcut` request: the property the wallpaper
/// named, and the value its user chose for that property.
using UserShortcutCallback = std::function<void(std::string_view, std::string_view)>;

constexpr std::string_view PROPERTY_SOURCE                    = "source";
constexpr std::string_view PROPERTY_ASSETS                    = "assets";
constexpr std::string_view PROPERTY_FPS                       = "fps";
constexpr std::string_view PROPERTY_FILLMODE                  = "fillmode";
constexpr std::string_view PROPERTY_SCALINGMODE               = "scalingmode";
constexpr std::string_view PROPERTY_SCALINGFACTOR             = "scalingfactor";
/// Internal rasterization scale in (0,1]. Distinct from PROPERTY_SCALINGFACTOR,
/// which scales the presented image on the output.
constexpr std::string_view PROPERTY_RENDER_SCALE              = "render_scale";
constexpr std::string_view PROPERTY_HORIZONTAL_FLIP            = "horizontal_flip";
constexpr std::string_view PROPERTY_SPEED                     = "speed";
constexpr std::string_view PROPERTY_GRAPHIVZ                  = "graphivz";
constexpr std::string_view PROPERTY_VOLUME                    = "volume";
constexpr std::string_view PROPERTY_MUTED                     = "muted";
constexpr std::string_view PROPERTY_AUDIO_RESPONSE_ENABLED    = "audio_response_enabled";
constexpr std::string_view PROPERTY_MEDIA_INTEGRATION_ENABLED = "media_integration_enabled";
constexpr std::string_view PROPERTY_MEDIA_EVENT_JSON          = "media_event_json";
constexpr std::string_view PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON =
    "project_property_override_json";
constexpr std::string_view PROPERTY_PROJECT_PROPERTY_RESET = "project_property_reset";
constexpr std::string_view PROPERTY_CACHE_PATH             = "cache_path";
constexpr std::string_view PROPERTY_FORCE_SHADER_REFRESH   = "force_shader_refresh";
constexpr std::string_view PROPERTY_FIRST_FRAME_CALLBACK   = "first_frame_callback";
constexpr std::string_view PROPERTY_POINTER_INPUT_CALLBACK = "pointer_input_callback";
constexpr std::string_view PROPERTY_USER_SHORTCUT_CALLBACK = "user_shortcut_callback";

#include "Core/NoCopyMove.hpp"
class MainHandler;
struct RenderInitInfo;
struct SceneWallpaperConfig {
    std::string source;
    std::string assets;
    std::string cache_path;
    std::string project_property_override_json;
    uint32_t    fps { 15 };
    bool        paused { false };
    bool        force_shader_refresh { false };
    bool        has_project_property_override { false };
};

class SceneWallpaper : NoCopy {
public:
    SceneWallpaper();
    ~SceneWallpaper();
    bool init();
    bool inited() const;
    void shutdown();

    void initVulkan(const RenderInitInfo&);
    void applyConfig(const SceneWallpaperConfig&);

    /// Pauses rendering and releases the Vulkan surface + swapchain on the
    /// render thread. Blocks until the render thread confirms completion.
    /// The scene, shaders, render graph, audio, and runtime state remain
    /// loaded. Returns false on any internal failure.
    bool beginSurfaceReconfigure();

    /// Rebuilds the Vulkan surface + swapchain on the render thread from a
    /// new RenderInitInfo and resumes rendering. Blocks until the render
    /// thread confirms completion.
    /// Preconditions: `beginSurfaceReconfigure` has returned true since the
    /// last successful init/finish. Returns false on failure.
    bool finishSurfaceReconfigure(const RenderInitInfo& info);

    void play();
    void pause();
    void setPaused(bool paused);
    void setSceneSource(std::string source);
    void setAssetsPath(std::string assets);
    void setCachePath(std::string cache_path);
    void setTargetFps(uint32_t fps);
    void mouseInput(double x, double y);
    void mouseButton(int button, bool pressed);
    void mouseButtonBaseline(uint32_t down);
    void mouseEnter(bool entered);
    void applySystemMediaArtwork(uint32_t width, uint32_t height, const uint8_t* rgba,
                                 std::size_t rgba_len);

    /// How this scene is currently being updated, and why.
    ///
    /// Pull-only live state, independent of diagnostic counting. Callers that
    /// have no renderer yet get `Continuous` with `UnknownInput`, never a
    /// value that reads as "nothing to do".
    [[nodiscard]] SceneUpdateDemand::Kind sceneUpdateKind() const;
    [[nodiscard]] uint32_t                sceneDemandReasons() const;

    /// Which renderer actually drew this scene, and why it is not the
    /// preferred one.
    ///
    /// Reports the backend in use, never the preference: a scene that fell
    /// back has to look like it fell back.
    [[nodiscard]] SceneBackendSelection sceneBackendSelection() const;
    /// How this scene's video textures reached the shaders sampling them on the
    /// last frame drawn.
    [[nodiscard]] SceneVideoPath sceneVideoPath() const;
    /// Whether this wallpaper's compiled graph is running under the current
    /// scene optimisation setting. False while a change is still waiting for
    /// the next frame, which is what distinguishes a saved preference from one
    /// that is really in force.
    [[nodiscard]] bool sceneOptimizationApplied() const;

    void setPropertyBool(std::string_view, bool);
    void setPropertyInt32(std::string_view, int32_t);
    void setPropertyFloat(std::string_view, float);
    void setPropertyString(std::string_view, std::string);
    void setPropertyObject(std::string_view, std::shared_ptr<void>);

    ExSwapchain* exSwapchain() const;

    // Ownership-transfer getter for the dma_fence sync_file fd that
    // was exported after the most recent completed offscreen frame.
    // Returns -1 if no frame has completed since the last call (or
    // export failed). The caller MUST close() the returned fd.
    int takeLastFrameSyncFd();

    /// Copies the renderer work counters for this surface. Returns how many
    /// values were written, which is never more than `len`. Safe to call from
    /// any thread: every counter is an independent atomic, so the result is a
    /// set of live readings rather than one consistent instant.
    std::size_t counters(uint64_t* out, std::size_t len) const;

private:
    bool m_inited { false };

private:
    friend class MainHandler;
#ifdef WESCENE_BUILD_TESTS
    friend struct SceneWallpaperInputTestAccess;
#endif

    bool                         m_offscreen { false };
    std::shared_ptr<MainHandler> m_main_handler;
};

#ifdef WESCENE_BUILD_TESTS
class Scene;
struct SceneWallpaperInputTestAccess {
    struct MouseButtonSnapshot {
        uint32_t down;
        uint32_t pressed;
        uint32_t released;
    };
    static void PostScene(SceneWallpaper&, std::shared_ptr<Scene>);
    static MouseButtonSnapshot ConsumeMouseButtons(SceneWallpaper&);
#if defined(__APPLE__)
    static SceneWallpaper& FromNative(owe_scene_wallpaper&);
#endif
};
#endif
} // namespace wallpaper
