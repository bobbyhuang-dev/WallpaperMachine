#include "SceneWallpaper.hpp"
#include "SceneWallpaperSurface.hpp"
#include "SceneSourceResolver.hpp"
#include "Project/ProjectProperties.hpp"

#include "Image.hpp"
#include "Utils/Logging.h"
#include "Looper/Looper.hpp"

#include "Timer/FrameTimer.hpp"
#include "Utils/FpsCounter.h"
#include "WPSceneParser.hpp"
#include "WPShaderParser.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneShader.h"
#include "Scene/SceneVertexArray.h"
#include "Particle/ParticleSystem.h"
#include "Interface/IImageParser.h"
#include "Interface/IShaderValueUpdater.h"

#include "Fs/VFS.h"
#include "Fs/PhysicalFs.h"
#include "WPPkgFs.hpp"

#include "Audio/SoundManager.h"
#include "Audio/FfmpegSoundStream.hpp"
#include "Video/FfmpegVideoTextureSource.hpp"
#include "Video/VideoFramePacing.hpp"

#include "RenderGraph/RenderGraph.hpp"

#include "SpecTexs.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "VulkanRender/VulkanRender.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include <algorithm>
#include <atomic>
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <limits>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

using namespace wallpaper;

#define CASE_CMD(cmd) \
    case CMD::CMD_##cmd: handle_##cmd(msg); break;
#define MHANDLER_CMD(cmd) void handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define MHANDLER_CMD_IMPL(cl, cmd) \
    void impl_##cl::handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define CALL_MHANDLER_CMD(cmd, msg) handle_##cmd(msg)

namespace
{
bool SetError(std::string* error, std::string message) {
    if (error != nullptr) *error = std::move(message);
    return false;
}

template<typename T>
void AddMsgCmd(looper::Message& msg, T cmd) {
    msg.setInt32("cmd", (int32_t)cmd);
}
template<typename T>
std::shared_ptr<looper::Message> CreateMsgWithCmd(const std::shared_ptr<looper::Handler>& handler,
                                                  T                                       cmd) {
    auto msg = looper::Message::create(0, handler);
    AddMsgCmd(*msg, cmd);
    return msg;
}

uint16_t ParsePkgVersionStamp(std::string_view stamp) {
    constexpr std::string_view prefix { "PKGV" };
    if (stamp.size() <= prefix.size() || stamp.substr(0, prefix.size()) != prefix) {
        return SceneParseRequest::kUnknownPkgVersion;
    }

    uint16_t    version { SceneParseRequest::kUnknownPkgVersion };
    const auto* first    = stamp.data() + prefix.size();
    const auto* last     = stamp.data() + stamp.size();
    const auto [ptr, ec] = std::from_chars(first, last, version);
    if (ec != std::errc {} || ptr != last) return SceneParseRequest::kUnknownPkgVersion;
    return version;
}

uint16_t ReadPkgVersionFromFile(const std::string& pkg_path) {
    std::ifstream input(pkg_path, std::ios::binary);
    if (! input.good()) return SceneParseRequest::kUnknownPkgVersion;

    int32_t length { 0 };
    input.read(reinterpret_cast<char*>(&length), sizeof(length));
    if (! input.good() || length <= 0 || length > 64) {
        return SceneParseRequest::kUnknownPkgVersion;
    }

    std::string stamp(static_cast<std::size_t>(length), '\0');
    input.read(stamp.data(), static_cast<std::streamsize>(stamp.size()));
    if (! input.good()) return SceneParseRequest::kUnknownPkgVersion;
    return ParsePkgVersionStamp(stamp);
}

class NoOpShaderValueUpdater final : public wallpaper::IShaderValueUpdater {
public:
    void FrameBegin() override {}
    void InitUniforms(wallpaper::SceneNode*, const wallpaper::ExistsUniformOp&) override {}
    void UpdateUniforms(wallpaper::SceneNode*, wallpaper::sprite_map_t&,
                        const wallpaper::UpdateUniformOp&) override {}
    void FrameEnd() override {}
    void MouseInput(double, double) override {}
    void SetTexelSize(float, float) override {}
    void SetScreenSize(i32, i32) override {}
};

class SingleVideoImageParser final : public wallpaper::IImageParser {
public:
    explicit SingleVideoImageParser(std::shared_ptr<wallpaper::Image> image)
        : m_image(std::move(image)) {}

    std::shared_ptr<wallpaper::Image> Parse(const std::string& name) override {
        if (m_image != nullptr && name == m_image->key) return m_image;
        return nullptr;
    }

    wallpaper::ImageHeader ParseHeader(const std::string& name) override {
        if (m_image != nullptr && name == m_image->key) return m_image->header;
        return {};
    }

private:
    std::shared_ptr<wallpaper::Image> m_image;
};

class ScopedGlslang final {
public:
    ScopedGlslang() { wallpaper::WPShaderParser::InitGlslang(); }
    ~ScopedGlslang() { wallpaper::WPShaderParser::FinalGlslang(); }
};

struct SystemMediaArtworkPayload {
    uint32_t             width { 0 };
    uint32_t             height { 0 };
    std::vector<uint8_t> rgba;
};

bool BuildVideoCopyShader(wallpaper::fs::VFS& vfs, std::string_view scene_id,
                          std::shared_ptr<wallpaper::SceneShader>* shader, std::string* error) {
    if (shader == nullptr) return SetError(error, "video copy shader output must not be null");

    std::string vertex_src = "in vec3 a_Position;\n"
                             "in vec2 a_TexCoord;\n"
                             "void main() {\n"
                             "gl_Position = vec4(a_Position, 1.0);\n"
                             "v_TexCoord = a_TexCoord;\n"
                             "}\n";

    std::string fragment_src = "uniform sampler2D g_Texture0;\n"
                               "in vec2 v_TexCoord;\n"
                               "void main() {\n"
                               "gl_FragColor = texture(g_Texture0, v_TexCoord);\n"
                               "}\n";

    wallpaper::WPShaderInfo                 shader_info;
    std::vector<wallpaper::WPShaderTexInfo> tex_infos(1);
    tex_infos[0].enabled = true;

    std::array units {
        wallpaper::WPShaderUnit {
            .stage           = wallpaper::ShaderType::VERTEX,
            .src             = std::move(vertex_src),
            .preprocess_info = {},
        },
        wallpaper::WPShaderUnit {
            .stage           = wallpaper::ShaderType::FRAGMENT,
            .src             = std::move(fragment_src),
            .preprocess_info = {},
        },
    };

    auto compiled_shader  = std::make_shared<wallpaper::SceneShader>();
    compiled_shader->name = "commands/copy";
    std::string reflection_json;
    if (! wallpaper::WPShaderParser::CompileToSpvRust(
            scene_id, "commands/copy", units, compiled_shader->codes, vfs, &shader_info, tex_infos, &reflection_json)) {
        return SetError(error, "failed to compile pure-video copy shader");
    }

    compiled_shader->rust_reflection_json = std::move(reflection_json);
    compiled_shader->default_uniforms = shader_info.svs;
    *shader                           = std::move(compiled_shader);
    return true;
}

void InstallVideoProjectCameras(wallpaper::Scene& scene) {
    scene.ortho[0] = 2;
    scene.ortho[1] = 2;

    auto global_node = std::make_shared<wallpaper::SceneNode>();
    scene.sceneGraph->AppendChild(global_node);

    auto global_camera = std::make_shared<wallpaper::SceneCamera>(2, 2, -1.0f, 1.0f);
    global_camera->AttatchNode(global_node);
    scene.cameras["global"] = global_camera;
    scene.activeCamera      = global_camera.get();

    auto perspective_node = std::make_shared<wallpaper::SceneNode>();
    scene.sceneGraph->AppendChild(perspective_node);

    auto perspective_camera = std::make_shared<wallpaper::SceneCamera>(1.0f, 0.1f, 1000.0f, 45.0f);
    perspective_camera->AttatchNode(perspective_node);
    scene.cameras["global_perspective"] = perspective_camera;
}

std::shared_ptr<wallpaper::SceneNode>
CreateVideoProjectNode(std::string_view                               texture_name,
                       const std::shared_ptr<wallpaper::SceneShader>& shader) {
    constexpr std::array<float, 12> positions {
        -1.0f, -1.0f, 0.0f, -1.0f, 1.0f, 0.0f, 1.0f, -1.0f, 0.0f, 1.0f, 1.0f, 0.0f,
    };
    constexpr std::array<float, 8> tex_coords {
        0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f,
    };

    auto                        mesh = std::make_shared<wallpaper::SceneMesh>();
    wallpaper::SceneVertexArray vertex(
        {
            { std::string(wallpaper::WE_IN_POSITION), wallpaper::VertexType::FLOAT3 },
            { std::string(wallpaper::WE_IN_TEXCOORD), wallpaper::VertexType::FLOAT2 },
        },
        4);
    vertex.SetVertex(wallpaper::WE_IN_POSITION, positions);
    vertex.SetVertex(wallpaper::WE_IN_TEXCOORD, tex_coords);
    mesh->AddVertexArray(std::move(vertex));

    wallpaper::SceneMaterial material;
    material.name = "video_project_copy";
    material.textures.push_back(std::string(texture_name));
    material.defines.push_back(std::string(wallpaper::WE_GLTEX_NAMES[0]));
    material.blenmode            = wallpaper::BlendMode::Normal;
    material.customShader.shader = shader;
    mesh->AddMaterial(std::move(material));

    auto node  = std::make_shared<wallpaper::SceneNode>();
    node->ID() = 1;
    node->AddMesh(mesh);
    return node;
}

std::shared_ptr<wallpaper::Scene>
CreateVideoProjectScene(std::unique_ptr<wallpaper::fs::VFS> vfs,
                        const std::filesystem::path&        project_path,
                        const wallpaper::ProjectManifest& manifest, std::string* error) {
    if (vfs == nullptr) {
        SetError(error, "video project VFS must not be null");
        return nullptr;
    }

    if (! wallpaper::InstallVirtualAssets(*vfs)) {
        SetError(error, "failed to install runtime virtual assets for video project");
        return nullptr;
    }

    auto image =
        wallpaper::video::CreateVideoProjectImage(project_path.parent_path(), manifest.file, error);
    if (image == nullptr) return nullptr;

    std::string scene_id = manifest.workshop_id;
    if (scene_id.empty()) {
        scene_id = project_path.parent_path().filename().string();
    }

    std::shared_ptr<wallpaper::SceneShader> shader;
    if (! BuildVideoCopyShader(*vfs, scene_id, &shader, error)) return nullptr;

    auto scene                = std::make_shared<wallpaper::Scene>();
    scene->accepts_pointer_input = false;
    // Everything below this line is what makes the claim true: one video
    // texture, a copy shader, a no-op shader value updater, and no script,
    // particle or audio layer. Keep them together so the marker cannot drift
    // away from the construction that justifies it.
    scene->single_video_source   = true;
    scene->scene_id           = scene_id;
    scene->clearColor         = { 0.0f, 0.0f, 0.0f };
    scene->shaderValueUpdater = std::make_unique<NoOpShaderValueUpdater>();
    scene->imageParser        = std::make_unique<SingleVideoImageParser>(image);
    scene->vfs                = std::move(vfs);

    InstallVideoProjectCameras(*scene);
    // This target holds one decoded frame at the resolution the file was
    // encoded at, so it is media-sized: an internal render scale must not
    // shrink it. Downsampling an already-decoded frame and upsampling it again
    // at present costs quality and saves almost nothing, because the decode it
    // would have to make cheaper is upstream of this target.
    const auto video_width  = std::max(1, image->header.width);
    const auto video_height = std::max(1, image->header.height);
    scene->scene_extent[0]  = video_width;
    scene->scene_extent[1]  = video_height;
    scene->renderTargets[std::string(wallpaper::SpecTex_Default)] = wallpaper::SceneRenderTarget {
        .width           = video_width,
        .height          = video_height,
        .authored_width  = video_width,
        .authored_height = video_height,
        .media_sized     = true,
        .bind            = { .enable = true, .screen = true },
    };
    scene->textures[image->key] = wallpaper::SceneTexture {
        .url     = image->key,
        .sample  = image->header.sample,
        .isVideo = true,
    };
    scene->sceneGraph->AppendChild(CreateVideoProjectNode(image->key, shader));

    return scene;
}
} // namespace

namespace wallpaper
{
class RenderHandler;

class MainHandler : public looper::Handler {
public:
    enum class CMD
    {
        CMD_LOAD_SCENE,
        CMD_APPLY_CONFIG,
        CMD_SET_PROPERTY,
        CMD_STOP,
        CMD_FIRST_FRAME,
        CMD_POINTER_INPUT_CHANGED,
        CMD_NO
    };

public:
    MainHandler();
    virtual ~MainHandler() {};

    bool init();
    void shutdown();
    auto renderHandler() const { return m_render_handler; }
    bool inited() const { return m_inited; }

public:
    void onMessageReceived(const std::shared_ptr<looper::Message>& msg) override {
        int32_t cmd_int = (int32_t)CMD::CMD_NO;
        if (msg->findInt32("cmd", &cmd_int)) {
            CMD cmd = static_cast<CMD>(cmd_int);
            switch (cmd) {
                CASE_CMD(APPLY_CONFIG);
                CASE_CMD(SET_PROPERTY);
                CASE_CMD(LOAD_SCENE);
                CASE_CMD(STOP);
                CASE_CMD(FIRST_FRAME);
                CASE_CMD(POINTER_INPUT_CHANGED);
            default: break;
            }
        }
    }

    void sendCmdLoadScene();
    void sendFirstFrameOk();
    void sendPointerInputCapability(bool accepts_pointer_input);
    bool isGenGraphviz() const { return m_gen_graphviz; }

private:
    bool applyConfig(SceneWallpaperConfig config);
    void setPaused(bool paused);
    bool setProjectPropertyOverrideJson(std::string json);
    bool resetProjectPropertyOverride();
    void loadScene();
    bool loadNonSceneProject(const ProjectManifest& manifest, std::unique_ptr<fs::VFS> vfs);

    MHANDLER_CMD(LOAD_SCENE);
    MHANDLER_CMD(APPLY_CONFIG);
    MHANDLER_CMD(SET_PROPERTY);
    MHANDLER_CMD(STOP);
    MHANDLER_CMD(FIRST_FRAME);
    MHANDLER_CMD(POINTER_INPUT_CHANGED);

private:
    bool m_inited { false };

    std::string m_assets;
    std::string m_source;
    std::string m_cache_path;
    std::string m_project_property_override_json;
    bool        m_gen_graphviz { false };
    bool        m_audio_response_enabled { false };
    bool        m_media_integration_enabled { false };
    bool        m_force_shader_refresh { false };

    WPSceneParser                        m_scene_parser;
    std::unique_ptr<audio::SoundManager> m_sound_manager;
    FirstFrameCallback                   m_first_frame_callback;
    PointerInputCallback                 m_pointer_input_callback;
    bool                                 m_accepts_pointer_input { true };

private:
    std::shared_ptr<looper::Looper> m_main_loop;
    std::shared_ptr<looper::Looper> m_render_loop;
    std::shared_ptr<RenderHandler>  m_render_handler;
};
// for macro
using impl_MainHandler = MainHandler;

class RenderHandler : public looper::Handler {
public:
    enum class CMD
    {
        CMD_INIT_VULKAN,
        CMD_SET_SCENE,
        CMD_SET_FILLMODE,
        CMD_SET_SCALINGMODE,
        CMD_SET_SCALINGFACTOR,
        CMD_SET_RENDER_SCALE,
        CMD_SET_HORIZONTAL_FLIP,
        CMD_SET_AUDIO_RESPONSE_ENABLED,
        CMD_SET_MEDIA_INTEGRATION_ENABLED,
        CMD_MEDIA_EVENT_JSON,
        CMD_SYSTEM_MEDIA_ARTWORK,
        CMD_SET_SPEED,
        CMD_STOP,
        CMD_DRAW,
        CMD_BEGIN_SURFACE_RECONFIGURE,
        CMD_FINISH_SURFACE_RECONFIGURE,
        CMD_NO
    };
    MainHandler& main_handler;
    RenderHandler(MainHandler& m)
        : main_handler(m), m_render(std::make_unique<vulkan::VulkanRender>()) {
        // Installed before anything can tick: the frame clock and the renderer
        // only ever read this pointer, and the counters outlive both.
        frame_timer.SetCounters(&counters);
        m_render->SetCounters(&counters);
        publishPauseReasons();
    }
    virtual ~RenderHandler() {
        frame_timer.Stop();
        m_render->destroy();
        LOG_INFO("render handler deleted");
    }

    void onMessageReceived(const std::shared_ptr<looper::Message>& msg) override {
        int32_t cmd_int = (int32_t)CMD::CMD_NO;
        if (msg->findInt32("cmd", &cmd_int)) {
            CMD cmd = static_cast<CMD>(cmd_int);
            switch (cmd) {
                CASE_CMD(DRAW);
                CASE_CMD(STOP);
                CASE_CMD(SET_FILLMODE);
                CASE_CMD(SET_SCALINGMODE);
                CASE_CMD(SET_SCALINGFACTOR);
                CASE_CMD(SET_HORIZONTAL_FLIP);
                CASE_CMD(SET_AUDIO_RESPONSE_ENABLED);
                CASE_CMD(SET_MEDIA_INTEGRATION_ENABLED);
                CASE_CMD(MEDIA_EVENT_JSON);
                CASE_CMD(SYSTEM_MEDIA_ARTWORK);
                CASE_CMD(SET_SCENE);
                CASE_CMD(SET_SPEED);
                CASE_CMD(INIT_VULKAN);
                CASE_CMD(BEGIN_SURFACE_RECONFIGURE);
                CASE_CMD(FINISH_SURFACE_RECONFIGURE);
            default: break;
            }
        }
    }

    ExSwapchain* exSwapchain() const { return m_render->exSwapchain(); }
    int          takeLastFrameSyncFd() { return m_render->takeLastFrameSyncFd(); }

    bool renderInited() const { return m_render->inited(); }

    /// Tells the frame clock how often this scene's content can actually
    /// change. Only the engine's own plain-video scene can answer: it is one
    /// video texture behind a copy shader with a no-op shader value updater and
    /// no script, particle, audio or pointer input, so the video's frame period
    /// is the whole scene's period. Rendering faster than that presents
    /// identical pixels. Every other scene reports nothing and keeps the fixed
    /// cadence, because an authored scene may change on a time uniform, a
    /// script, a particle system, audio or a feedback texture that this code
    /// does not enumerate.
    ///
    /// **Opt-in, and the reason is a bound this function cannot remove.** The
    /// period only reaches the frame clock from here, and this runs after a
    /// completed frame. A source whose rate turns out to be tighter than the
    /// interval currently being waited out therefore produces frames that are
    /// superseded before the next frame boundary — up to
    /// `interval / period - 1` of them. Removing that needs the source to wake
    /// the clock itself, which is a different change. Until then the default is
    /// the safe baseline: tick at the configured ceiling.
    ///
    /// Runs on the render thread; the frame clock only reads the value it
    /// stores.
    void refreshFrameDemand() {
        // Also the A/B entry point, so a comparison measures one scheduling
        // strategy in one binary rather than two builds. Read per frame now
        // that it is a live setting rather than an environment variable: the
        // read is one relaxed atomic load, and a user toggling the option has
        // to take effect without restarting the wallpaper.
        const bool pacing_enabled = video::ContentPacingEnabled();

        FrameTimer::FrameDemand demand {};
        if (pacing_enabled && m_scene != nullptr && m_scene->single_video_source &&
            renderInited()) {
            // The source reports a period on the media's own timeline. Playback
            // speed maps it onto the wall clock, so a 2x wallpaper needs twice
            // the tick rate for the same content.
            const double period_seconds = video::ResolveContentPeriodSeconds(
                m_render->ShortestVideoFramePeriod(), static_cast<double>(m_speed));
            if (period_seconds > 0.0) {
                demand.content_period = std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::duration<double>(period_seconds));
            }
        }
        frame_timer.SetFrameDemand(demand);
    }

    /// Why this surface is not presenting, as independent bits. Recomputed on
    /// every transition that can change one of them, so a stopped surface can
    /// be told apart from a surface whose renderer was taken away.
    void publishPauseReasons() {
        uint64_t reasons = OWE_RC_PAUSE_NONE;
        if (! frame_timer.Running()) reasons |= OWE_RC_PAUSE_CLOCK_STOPPED;
        if (m_render_blocked || ! renderInited()) reasons |= OWE_RC_PAUSE_RENDER_BLOCKED;
        if (m_scene == nullptr) reasons |= OWE_RC_PAUSE_NO_SCENE;
        counters.Set(OWE_RC_PAUSE_REASONS, reasons);
    }

    struct MouseButtonSnapshot {
        uint32_t down { 0 };
        uint32_t pressed { 0 };
        uint32_t released { 0 };
    };

    void setMousePos(double x, double y) {
        m_mouse_pos.store(std::array {
            std::clamp(static_cast<float>(x), 0.0f, 1.0f),
            std::clamp(static_cast<float>(y), 0.0f, 1.0f),
        });
    }
    void setMouseButton(int button, bool pressed) {
        if (button < 0 || button > 31) return;
        const uint32_t   mask = 1u << static_cast<uint32_t>(button);
        std::scoped_lock lock(m_mouse_buttons_mutex);
        if (pressed) {
            if ((m_mouse_buttons.down & mask) == 0) {
                m_mouse_buttons.down |= mask;
                m_mouse_buttons.pressed |= mask;
            }
            return;
        }
        if ((m_mouse_buttons.down & mask) != 0) {
            m_mouse_buttons.down &= ~mask;
            m_mouse_buttons.released |= mask;
        }
    }
    void setMouseButtonBaseline(uint32_t down) {
        std::scoped_lock lock(m_mouse_buttons_mutex);
        m_mouse_buttons.down = down;
    }
    void setMouseInWindow(bool entered) { m_cursor_in_window.store(entered); }

private:
#ifdef WESCENE_BUILD_TESTS
    friend struct SceneWallpaperInputTestAccess;
#endif
    MouseButtonSnapshot consumeMouseButtonSnapshot() {
        std::scoped_lock    lock(m_mouse_buttons_mutex);
        MouseButtonSnapshot snapshot = m_mouse_buttons;
        m_mouse_buttons.pressed      = 0;
        m_mouse_buttons.released     = 0;
        return snapshot;
    }

    void suspendRendering() {
        m_render_blocked = true;
        frame_timer.Stop();
        publishPauseReasons();
    }

    bool rebuildRenderGraph() {
        if (m_scene == nullptr) return true;

        if (m_rg && ! m_render->clearLastRenderGraph()) {
            suspendRendering();
            return false;
        }
        // Seed the scale before the graph is compiled so render targets are
        // allocated at the requested size once, instead of at full size and
        // then immediately resized.
        m_scene->render_scale = m_render_scale;
        m_rg = sceneToRenderGraph(*m_scene);

        if (main_handler.isGenGraphviz()) m_rg->ToGraphviz("graph.dot");
        if (! m_render->compileRenderGraph(*m_scene, *m_rg)) {
            suspendRendering();
            return false;
        }
        m_render->SetWallpaperScalingMode(m_scalingmode);
        m_render->SetWallpaperScalingFactor(m_scalingfactor);
        m_render->SetWallpaperHorizontalFlip(m_horizontal_flip);
        if (m_fillmode_explicit) {
            m_render->UpdateCameraFillMode(*m_scene, m_fillmode);
        }
        if (m_scene->runtime != nullptr) {
            m_scene->runtime->ConsumeSceneGraphMutationFlag();
        }
        m_render_blocked = false;
        return true;
    }

    bool applySystemMediaArtworkPayload(const SystemMediaArtworkPayload& artwork) {
        if (m_scene == nullptr || m_scene->imageParser == nullptr) return false;

        auto* runtime_images = dynamic_cast<RuntimeImageSource*>(m_scene->imageParser.get());
        if (runtime_images == nullptr) return false;

        runtime_images->SetRgbaImage("$mediaThumbnail",
                                     artwork.width,
                                     artwork.height,
                                     artwork.rgba.data(),
                                     artwork.rgba.size());
        if (m_scene->runtime != nullptr) {
            m_scene->runtime->DispatchMediaEventJson(
                R"({"type":"mediaThumbnailChanged","hasThumbnail":true})");
        }
        return rebuildRenderGraph();
    }

    MHANDLER_CMD(STOP) {
        bool stop { false };
        if (msg->findBool("value", &stop)) {
            if (renderInited()) {
                m_render->SetVideoPlaybackPaused(stop || m_render_blocked);
            }
            if (stop || m_render_blocked)
                frame_timer.Stop();
            else
                frame_timer.Run();
            refreshFrameDemand();
            publishPauseReasons();
        }
    }
    MHANDLER_CMD(DRAW) {
        if (m_render_blocked) {
            // The tick that posted this draw still counted; the work it asked
            // for did not happen, and that difference is the whole point.
            counters.Add(OWE_RC_DRAWS_DROPPED);
            return;
        }
        counters.Add(OWE_RC_DRAWS_EXECUTED);
        frame_timer.FrameBegin();
        if (m_rg) {
            const double frame_time = frame_timer.IdeaTime() * m_speed;
            // LOG_INFO("frame info, fps: %.1f, frametime: %.1f", 1.0f, 1000.0f*m_scene->frameTime);
            m_scene->shaderValueUpdater->FrameBegin();
            {
                auto pos = m_mouse_pos.load();
                if (m_horizontal_flip) {
                    pos[0] = 1.0f - pos[0];
                }
                m_scene->pointerPosition = pos;
                m_scene->shaderValueUpdater->MouseInput(pos[0], pos[1]);
                if (m_scene->runtime != nullptr) {
                    const auto mapping = m_render->CursorMapping(*m_scene);
                    if (mapping.valid) {
                        m_scene->runtime->SetCursorViewport(CursorViewport {
                            .origin = Eigen::Vector2f(static_cast<float>(mapping.origin_x),
                                                      static_cast<float>(mapping.origin_y)),
                            .size   = Eigen::Vector2f(static_cast<float>(mapping.size_x),
                                                    static_cast<float>(mapping.size_y)),
                            .content_origin =
                                Eigen::Vector2f(static_cast<float>(mapping.content_origin_x),
                                                static_cast<float>(mapping.content_origin_y)),
                            .content_size =
                                Eigen::Vector2f(static_cast<float>(mapping.content_size_x),
                                                static_cast<float>(mapping.content_size_y)),
                        });
                    }
                    m_scene->runtime->SetCursorInput(pos[0], pos[1]);
                    m_scene->runtime->SetCursorEnter(m_cursor_in_window.load());
                    const MouseButtonSnapshot buttons = consumeMouseButtonSnapshot();
                    m_scene->runtime->SetCursorButtons(
                        buttons.down, buttons.pressed, buttons.released);
                    m_cursor_was_in_window =
                        m_scene->runtime->DispatchCursorFrameEvents(m_cursor_was_in_window);
                }
            }
            m_scene->paritileSys->Emitt();
            bool frame_ok = true;
            if (m_scene->runtime != nullptr) {
                m_scene->runtime->Tick(frame_time);
                m_scene->runtime->PumpTextLayerCache();
                if (m_scene->runtime->ConsumeSceneGraphMutationFlag()) {
                    frame_ok = rebuildRenderGraph();
                }
            }

            if (frame_ok) frame_ok = m_render->drawFrame(*m_scene);
            if (frame_ok) {
                m_scene->PassFrameTime(frame_time);
                counters.Add(OWE_RC_SIMULATION_TICKS);
            } else {
                counters.Add(OWE_RC_RENDER_FAILURES);
                suspendRendering();
            }

            m_scene->shaderValueUpdater->FrameEnd();
            // fps_counter.RegisterFrame();

            if (frame_ok && ! m_scene->first_frame_ok) {
                m_scene->first_frame_ok = true;
                main_handler.sendFirstFrameOk();
            }
        }
        frame_timer.FrameEnd();
        refreshFrameDemand();
    }
    MHANDLER_CMD(SET_FILLMODE) {
        int32_t value;
        if (msg->findInt32("value", &value)) {
            m_fillmode          = (FillMode)value;
            m_fillmode_explicit = true;
            if (m_scene && renderInited()) {
                m_render->UpdateCameraFillMode(*m_scene, m_fillmode);
            }
        }
    }
    MHANDLER_CMD(SET_SCALINGMODE) {
        int32_t value;
        if (msg->findInt32("value", &value)) {
            m_scalingmode = static_cast<WallpaperScalingMode>(value);
            if (renderInited()) {
                m_render->SetWallpaperScalingMode(m_scalingmode);
            }
        }
    }
    MHANDLER_CMD(SET_SCALINGFACTOR) {
        float value;
        if (msg->findFloat("value", &value)) {
            m_scalingfactor = value;
            if (renderInited()) {
                m_render->SetWallpaperScalingFactor(m_scalingfactor);
            }
        }
    }
    MHANDLER_CMD(SET_RENDER_SCALE) {
        float value { 1.0f };
        if (msg->findFloat("value", &value)) {
            m_render_scale = value;
            if (renderInited() && m_scene != nullptr && m_rg) {
                if (! m_render->ApplyRenderScale(*m_scene, *m_rg, m_render_scale)) {
                    // A failed resize leaves the passes unprepared, so fall back
                    // to the full graph rebuild rather than presenting nothing.
                    LOG_ERROR("render scale change failed, rebuilding render graph");
                    rebuildRenderGraph();
                }
            } else if (m_scene != nullptr) {
                m_scene->render_scale = value;
            }
        }
    }
    MHANDLER_CMD(SET_HORIZONTAL_FLIP) {
        bool value { false };
        if (msg->findBool("value", &value)) {
            m_horizontal_flip = value;
            if (renderInited()) {
                m_render->SetWallpaperHorizontalFlip(m_horizontal_flip);
            }
        }
    }
    MHANDLER_CMD(SET_AUDIO_RESPONSE_ENABLED) {
        bool enabled { false };
        if (msg->findBool("value", &enabled)) {
            if (m_scene != nullptr && m_scene->runtime != nullptr) {
                m_scene->runtime->SetAudioResponseEnabled(enabled);
            }
        }
    }
    MHANDLER_CMD(SET_MEDIA_INTEGRATION_ENABLED) {
        bool enabled { false };
        if (msg->findBool("value", &enabled)) {
            m_media_integration_enabled = enabled;
            if (m_scene != nullptr && m_scene->runtime != nullptr) {
                m_scene->runtime->SetMediaIntegrationEnabled(enabled);
            }
        }
    }
    MHANDLER_CMD(MEDIA_EVENT_JSON) {
        if (! m_media_integration_enabled || m_scene == nullptr || m_scene->runtime == nullptr)
            return;

        std::string json;
        if (msg->findString("value", &json)) {
            m_scene->runtime->DispatchMediaEventJson(json);
        }
    }
    MHANDLER_CMD(SYSTEM_MEDIA_ARTWORK) {
        std::shared_ptr<SystemMediaArtworkPayload> artwork;
        if (! msg->findObject("artwork", &artwork) || artwork == nullptr || artwork->rgba.empty())
            return;
        if (! applySystemMediaArtworkPayload(*artwork)) {
            m_pending_system_media_artwork = *artwork;
        } else {
            m_pending_system_media_artwork.reset();
        }
    }
    MHANDLER_CMD(SET_SCENE) {
        std::shared_ptr<Scene> scene;
        if (msg->findObject("scene", &scene)) {
            if (m_rg && ! m_render->clearLastRenderGraph()) {
                suspendRendering();
                return;
            }
            m_rg.reset();
            const bool previous_accepts_pointer_input =
                m_scene == nullptr || m_scene->accepts_pointer_input;
            const bool accepts_pointer_input = scene == nullptr || scene->accepts_pointer_input;
            {
                std::scoped_lock lock(m_mouse_buttons_mutex);
                m_scene = std::move(scene);
                if (!previous_accepts_pointer_input || !accepts_pointer_input) {
                    m_mouse_buttons.pressed  = 0;
                    m_mouse_buttons.released = 0;
                }
            }
            main_handler.sendPointerInputCapability(accepts_pointer_input);
            m_render_blocked = false;
            if (m_scene != nullptr && m_scene->runtime != nullptr) {
                m_scene->runtime->SetMediaIntegrationEnabled(m_media_integration_enabled);
            }
            if (m_pending_system_media_artwork.has_value() &&
                applySystemMediaArtworkPayload(*m_pending_system_media_artwork)) {
                m_pending_system_media_artwork.reset();
            } else if (! m_render_blocked && ! rebuildRenderGraph()) {
                return;
            }
        }
    }
    MHANDLER_CMD(SET_SPEED) {
        if (msg->findFloat("value", &m_speed) && renderInited()) {
            m_render->SetVideoPlaybackRate(m_speed);
            // Speed maps the content's own timeline onto the wall clock, so the
            // tick rate a video needs changes with it.
            refreshFrameDemand();
        }
    }
    MHANDLER_CMD(INIT_VULKAN) {
        std::shared_ptr<RenderInitInfo> info;
        if (msg->findObject("info", &info) && info != nullptr) {
            if (! m_render->init(*info)) {
                suspendRendering();
                return;
            }
            m_render_blocked = false;
            m_render->SetWallpaperScalingMode(m_scalingmode);
            m_render->SetWallpaperScalingFactor(m_scalingfactor);
            m_render->SetWallpaperHorizontalFlip(m_horizontal_flip);
            m_render->SetVideoPlaybackRate(m_speed);
            m_render->SetVideoPlaybackPaused(! frame_timer.Running());

            // Initialization succeeded; dispatch scene loading.
            main_handler.sendCmdLoadScene();
            publishPauseReasons();
        }
    }
    MHANDLER_CMD(BEGIN_SURFACE_RECONFIGURE) {
        std::shared_ptr<std::promise<bool>> promise;
        if (! msg->findObject("promise", &promise) || promise == nullptr) {
            return;
        }
        try {
            suspendRendering();
            bool ok = true;
            if (renderInited()) {
                m_render->SetVideoPlaybackPaused(true);
                ok = m_render->releaseSurface();
            }
            promise->set_value(ok);
        } catch (...) {
            promise->set_value(false);
        }
    }
    MHANDLER_CMD(FINISH_SURFACE_RECONFIGURE) {
        std::shared_ptr<std::promise<bool>> promise;
        std::shared_ptr<RenderInitInfo>     info;
        if (! msg->findObject("promise", &promise) || promise == nullptr) {
            return;
        }
        suspendRendering();
        if (! msg->findObject("info", &info) || info == nullptr) {
            promise->set_value(false);
            return;
        }
        try {
            const bool ok = m_render->resetSurface(*info) && rebuildRenderGraph();
            if (ok) {
                m_render_blocked = false;
                m_render->SetVideoPlaybackPaused(false);
                frame_timer.Run();
                refreshFrameDemand();
                publishPauseReasons();
            }
            promise->set_value(ok);
        } catch (...) {
            suspendRendering();
            promise->set_value(false);
        }
    }

public:
    FrameTimer       frame_timer;
    FpsCounter       fps_counter;
    /// Written by the frame clock, the render thread and the decode thread;
    /// read by whoever asks for a snapshot. The destructor stops the frame
    /// clock and destroys the renderer before any member is destroyed, so no
    /// writer outlives it.
    RendererCounters counters;

private:
    std::shared_ptr<Scene> m_scene { nullptr };
    float                  m_speed { 1.0f };

    std::unique_ptr<vulkan::VulkanRender> m_render;
    std::unique_ptr<rg::RenderGraph>      m_rg { nullptr };
    bool                                m_render_blocked { false };

    FillMode                                 m_fillmode { FillMode::ASPECTFIT };
    bool                                     m_fillmode_explicit { false };
    WallpaperScalingMode                     m_scalingmode { WallpaperScalingMode::FIT };
    float                                    m_scalingfactor { 1.0f };
    /// Internal rasterization scale, independent of `m_scalingfactor`: that one
    /// scales the presented image on the output, this one only changes how many
    /// pixels the scene is drawn with.
    float                                    m_render_scale { 1.0f };
    bool                                     m_horizontal_flip { false };
    bool                                     m_media_integration_enabled { false };
    std::optional<SystemMediaArtworkPayload> m_pending_system_media_artwork {};

    std::atomic<std::array<float, 2>> m_mouse_pos { std::array { 0.5f, 0.5f } };
    std::mutex                        m_mouse_buttons_mutex;
    MouseButtonSnapshot               m_mouse_buttons {};
    std::atomic<bool>                 m_cursor_in_window { false };
    bool                              m_cursor_was_in_window { false };
};
} // namespace wallpaper

SceneWallpaper::SceneWallpaper(): m_main_handler(std::make_shared<MainHandler>()) {}

SceneWallpaper::~SceneWallpaper() { shutdown(); }

bool SceneWallpaper::inited() const { return m_main_handler->inited(); }

bool SceneWallpaper::init() { return m_main_handler->init(); }

void SceneWallpaper::shutdown() {
    if (m_main_handler != nullptr) {
        m_main_handler->shutdown();
    }
}

#ifdef WESCENE_BUILD_TESTS
void SceneWallpaperInputTestAccess::PostScene(SceneWallpaper& wallpaper,
                                             std::shared_ptr<Scene> scene) {
    auto msg = CreateMsgWithCmd(wallpaper.m_main_handler->renderHandler(),
                               RenderHandler::CMD::CMD_SET_SCENE);
    msg->setObject("scene", std::move(scene));
    msg->post();
}

SceneWallpaperInputTestAccess::MouseButtonSnapshot
SceneWallpaperInputTestAccess::ConsumeMouseButtons(SceneWallpaper& wallpaper) {
    const auto snapshot =
        wallpaper.m_main_handler->renderHandler()->consumeMouseButtonSnapshot();
    return { snapshot.down, snapshot.pressed, snapshot.released };
}
#endif

void SceneWallpaper::initVulkan(const RenderInitInfo& info) {
    m_offscreen                             = info.offscreen;
    std::shared_ptr<RenderInitInfo> sp_info = std::make_shared<RenderInitInfo>(info);
    auto                            msg =
        CreateMsgWithCmd(m_main_handler->renderHandler(), RenderHandler::CMD::CMD_INIT_VULKAN);
    msg->setObject("info", sp_info);
    msg->post();
}

bool SceneWallpaper::beginSurfaceReconfigure() {
    if (m_main_handler == nullptr || m_main_handler->renderHandler() == nullptr) {
        return false;
    }
    auto promise = std::make_shared<std::promise<bool>>();
    auto future  = promise->get_future();
    auto msg     = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_BEGIN_SURFACE_RECONFIGURE);
    msg->setObject("promise", promise);
    msg->post();
    return future.get();
}

bool SceneWallpaper::finishSurfaceReconfigure(const RenderInitInfo& info) {
    if (m_main_handler == nullptr || m_main_handler->renderHandler() == nullptr) {
        return false;
    }
    auto promise = std::make_shared<std::promise<bool>>();
    auto future  = promise->get_future();
    auto sp_info = std::make_shared<RenderInitInfo>(info);
    auto msg     = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_FINISH_SURFACE_RECONFIGURE);
    msg->setObject("promise", promise);
    msg->setObject("info", sp_info);
    msg->post();
    return future.get();
}

void SceneWallpaper::applyConfig(const SceneWallpaperConfig& config) {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_APPLY_CONFIG);
    msg->setObject("config", std::make_shared<SceneWallpaperConfig>(config));
    msg->post();
}

void SceneWallpaper::play() {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_STOP);
    msg->setBool("value", false);
    msg->post();
}
void SceneWallpaper::pause() {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_STOP);
    msg->setBool("value", true);
    msg->post();
}

void SceneWallpaper::setPaused(bool paused) {
    if (paused) {
        pause();
        return;
    }
    play();
}

void SceneWallpaper::setSceneSource(std::string source) {
    setPropertyString(PROPERTY_SOURCE, std::move(source));
}

void SceneWallpaper::setAssetsPath(std::string assets) {
    setPropertyString(PROPERTY_ASSETS, std::move(assets));
}

void SceneWallpaper::setCachePath(std::string cache_path) {
    setPropertyString(PROPERTY_CACHE_PATH, std::move(cache_path));
}

void SceneWallpaper::setTargetFps(uint32_t fps) {
    setPropertyInt32(PROPERTY_FPS, static_cast<int32_t>(fps));
}

void SceneWallpaper::mouseInput(double x, double y) {
    m_main_handler->renderHandler()->setMousePos(x, y);
}

void SceneWallpaper::mouseButton(int button, bool pressed) {
    m_main_handler->renderHandler()->setMouseButton(button, pressed);
}

void SceneWallpaper::mouseButtonBaseline(uint32_t down) {
    m_main_handler->renderHandler()->setMouseButtonBaseline(down);
}

void SceneWallpaper::mouseEnter(bool entered) {
    m_main_handler->renderHandler()->setMouseInWindow(entered);
}

void SceneWallpaper::applySystemMediaArtwork(uint32_t width, uint32_t height, const uint8_t* rgba,
                                             std::size_t rgba_len) {
    if (width == 0 || height == 0 || rgba == nullptr) return;
    if (width > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
        height > static_cast<uint32_t>(std::numeric_limits<int32_t>::max())) {
        return;
    }
    const std::size_t pixel_count = static_cast<std::size_t>(width) * height;
    if (pixel_count > std::numeric_limits<std::size_t>::max() / 4) return;
    const std::size_t expected_len = pixel_count * 4;
    if (rgba_len != expected_len) return;

    auto artwork    = std::make_shared<SystemMediaArtworkPayload>();
    artwork->width  = width;
    artwork->height = height;
    artwork->rgba.resize(rgba_len);
    std::memcpy(artwork->rgba.data(), rgba, rgba_len);

    auto msg = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_SYSTEM_MEDIA_ARTWORK);
    msg->setObject("artwork", artwork);
    msg->post();
}

#define BASIC_TYPE(NAME, TYPENAME)                                                       \
    void SceneWallpaper::setProperty##NAME(std::string_view name, TYPENAME value) {      \
        auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_SET_PROPERTY); \
        msg->setString("property", std::string(name));                                   \
        msg->set##NAME("value", value);                                                  \
        msg->post();                                                                     \
    }

BASIC_TYPE(Bool, bool);
BASIC_TYPE(Int32, int32_t);
BASIC_TYPE(Float, float);
BASIC_TYPE(String, std::string);
void SceneWallpaper::setPropertyObject(std::string_view name, std::shared_ptr<void> value) {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_SET_PROPERTY);
    if (! msg->setString("property", std::string(name)) || ! msg->setObject("value", value)) {
        throw std::runtime_error("failed to prepare object property message");
    }
    if (msg->post() != looper::status_t::OK) {
        throw std::runtime_error("failed to enqueue object property message");
    }
}

int SceneWallpaper::takeLastFrameSyncFd() {
    return m_main_handler->renderHandler()->takeLastFrameSyncFd();
}

ExSwapchain* SceneWallpaper::exSwapchain() const {
    return m_main_handler->renderHandler()->exSwapchain();
}

std::size_t SceneWallpaper::counters(uint64_t* out, std::size_t len) const {
    if (m_main_handler == nullptr) return 0;
    const auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return 0;
    return handler->counters.Snapshot(out, len);
}

MHANDLER_CMD_IMPL(MainHandler, LOAD_SCENE) {
    if (m_render_handler->renderInited()) {
        loadScene();
    }
}

MHANDLER_CMD_IMPL(MainHandler, APPLY_CONFIG) {
    std::shared_ptr<SceneWallpaperConfig> config;
    if (! msg->findObject("config", &config) || config == nullptr) return;

    const bool paused      = config->paused;
    const bool should_load = applyConfig(std::move(*config));
    if (should_load && m_render_handler != nullptr) CALL_MHANDLER_CMD(LOAD_SCENE, msg);
    setPaused(paused);
}

MHANDLER_CMD_IMPL(MainHandler, SET_PROPERTY) {
    std::string property;
    if (msg->findString("property", &property)) {
        if (property == PROPERTY_SOURCE) {
            msg->findString("value", &m_source);
            LOG_INFO("source: %s", m_source.c_str());
            CALL_MHANDLER_CMD(LOAD_SCENE, msg);
        } else if (property == PROPERTY_ASSETS) {
            msg->findString("value", &m_assets);
            CALL_MHANDLER_CMD(LOAD_SCENE, msg);
        } else if (property == PROPERTY_FPS) {
            int32_t fps { 0 };
            msg->findInt32("value", &fps);
            if (fps > 0) {
                m_render_handler->frame_timer.SetRequiredFps(
                    (u16)std::min<int32_t>(fps, UINT16_MAX));
            }
        } else if (property == PROPERTY_FILLMODE) {
            int32_t value;
            if (msg->findInt32("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_FILLMODE);
                nmsg->setInt32("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_SCALINGMODE) {
            int32_t value;
            if (msg->findInt32("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCALINGMODE);
                nmsg->setInt32("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_SCALINGFACTOR) {
            float value;
            if (msg->findFloat("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCALINGFACTOR);
                nmsg->setFloat("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_RENDER_SCALE) {
            float value { 1.0f };
            if (msg->findFloat("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_RENDER_SCALE);
                nmsg->setFloat("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_HORIZONTAL_FLIP) {
            bool value { false };
            if (msg->findBool("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_HORIZONTAL_FLIP);
                nmsg->setBool("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_GRAPHIVZ) {
            msg->findBool("value", &m_gen_graphviz);
        } else if (property == PROPERTY_MUTED) {
            bool muted { false };
            msg->findBool("value", &muted);
            m_sound_manager->SetMuted(muted);
        } else if (property == PROPERTY_VOLUME) {
            float volume { 1.0f };
            msg->findFloat("value", &volume);
            m_sound_manager->SetVolume(volume);
        } else if (property == PROPERTY_AUDIO_RESPONSE_ENABLED) {
            bool enabled { false };
            msg->findBool("value", &enabled);
            m_audio_response_enabled = enabled;
            auto nmsg                = CreateMsgWithCmd(m_render_handler,
                                         RenderHandler::CMD::CMD_SET_AUDIO_RESPONSE_ENABLED);
            nmsg->setBool("value", enabled);
            nmsg->post();
        } else if (property == PROPERTY_MEDIA_INTEGRATION_ENABLED) {
            bool enabled { false };
            msg->findBool("value", &enabled);
            m_media_integration_enabled = enabled;
            if (m_render_handler != nullptr) {
                auto nmsg = CreateMsgWithCmd(m_render_handler,
                                             RenderHandler::CMD::CMD_SET_MEDIA_INTEGRATION_ENABLED);
                nmsg->setBool("value", enabled);
                nmsg->post();
            }
        } else if (property == PROPERTY_MEDIA_EVENT_JSON) {
            std::string json;
            if (msg->findString("value", &json) && m_media_integration_enabled &&
                m_render_handler != nullptr) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_MEDIA_EVENT_JSON);
                nmsg->setString("value", json);
                nmsg->post();
            }
        } else if (property == PROPERTY_CACHE_PATH) {
            std::string path;
            msg->findString("value", &path);
            m_cache_path = path;
        } else if (property == PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON) {
            std::string json;
            msg->findString("value", &json);
            if (setProjectPropertyOverrideJson(std::move(json)) && m_render_handler != nullptr)
                CALL_MHANDLER_CMD(LOAD_SCENE, msg);
        } else if (property == PROPERTY_PROJECT_PROPERTY_RESET) {
            bool reset { false };
            msg->findBool("value", &reset);
            if (reset && resetProjectPropertyOverride()) {
                if (m_render_handler != nullptr) CALL_MHANDLER_CMD(LOAD_SCENE, msg);
            }
        } else if (property == PROPERTY_FORCE_SHADER_REFRESH) {
            msg->findBool("value", &m_force_shader_refresh);
        } else if (property == PROPERTY_FIRST_FRAME_CALLBACK) {
            std::shared_ptr<FirstFrameCallback> cb;
            msg->findObject("value", &cb);
            m_first_frame_callback = *cb;
        } else if (property == PROPERTY_POINTER_INPUT_CALLBACK) {
            std::shared_ptr<PointerInputCallback> cb;
            if (msg->findObject("value", &cb) && cb != nullptr) {
                m_pointer_input_callback = std::move(*cb);
                if (m_pointer_input_callback) m_pointer_input_callback(m_accepts_pointer_input);
            }
        } else if (property == PROPERTY_SPEED) {
            float speed { 1.0f };
            if (msg->findFloat("value", &speed)) {
                auto nmsg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SPEED);
                nmsg->setFloat("value", speed);
                nmsg->post();
            }
        }
    }
}

MHANDLER_CMD_IMPL(MainHandler, STOP) {
    bool stop { false };
    if (msg->findBool("value", &stop)) {
        setPaused(stop);
    }
}

MHANDLER_CMD_IMPL(MainHandler, FIRST_FRAME) {
    if (m_first_frame_callback) m_first_frame_callback();
}

MHANDLER_CMD_IMPL(MainHandler, POINTER_INPUT_CHANGED) {
    if (msg->findBool("accepts_pointer_input", &m_accepts_pointer_input) &&
        m_pointer_input_callback) {
        m_pointer_input_callback(m_accepts_pointer_input);
    }
}

bool MainHandler::applyConfig(SceneWallpaperConfig config) {
    bool should_load = false;

    if (m_source != config.source) {
        m_source = std::move(config.source);
        LOG_INFO("source: %s", m_source.c_str());
        should_load = true;
    }
    if (m_assets != config.assets) {
        m_assets    = std::move(config.assets);
        should_load = true;
    }
    if (m_cache_path != config.cache_path) {
        m_cache_path = std::move(config.cache_path);
        should_load  = true;
    }

    if (config.has_project_property_override) {
        should_load =
            setProjectPropertyOverrideJson(std::move(config.project_property_override_json)) ||
            should_load;
    } else {
        should_load = resetProjectPropertyOverride() || should_load;
    }

    m_force_shader_refresh = config.force_shader_refresh;
    if (m_force_shader_refresh) should_load = true;

    if (config.fps > 0) {
        m_render_handler->frame_timer.SetRequiredFps(
            (u16)std::min<uint32_t>(config.fps, UINT16_MAX));
    }

    return should_load;
}

void MainHandler::setPaused(bool paused) {
    if (paused) {
        m_sound_manager->Pause();
    } else {
        m_sound_manager->Play();
    }

    auto msg_r = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_STOP);
    msg_r->setBool("value", paused);
    msg_r->post();
}

bool MainHandler::setProjectPropertyOverrideJson(std::string json) {
    if (m_project_property_override_json == json) return false;
    m_project_property_override_json = std::move(json);
    return true;
}

bool MainHandler::resetProjectPropertyOverride() {
    if (m_project_property_override_json.empty()) return false;
    m_project_property_override_json.clear();
    return true;
}

void MainHandler::loadScene() {
    if (m_source.empty()) return;

    LOG_INFO("loading scene: %s", m_source.c_str());

    if (! m_sound_manager->IsInited()) {
        m_sound_manager->Init();
        m_sound_manager->Play();
    } else {
        m_sound_manager->UnMountAll();
    }

    std::shared_ptr<Scene> scene { nullptr };

    // mount assets dir
    std::unique_ptr<fs::VFS> pVfs = std::make_unique<fs::VFS>();
    auto&                    vfs  = *pVfs;
    SceneSourceResolution source_resolution;
    std::string           source_error;
    if (! ResolveSceneSourcePaths(m_source, &source_resolution, &source_error)) {
        LOG_ERROR("failed to resolve scene source %s: %s", m_source.c_str(), source_error.c_str());
        return;
    }
    if (source_resolution.kind != SceneSourceResolutionKind::Scene) {
        loadNonSceneProject(source_resolution.manifest, std::move(pVfs));
        return;
    }
    if (! vfs.IsMounted("assets")) {
        bool sus = vfs.Mount("/assets", fs::CreatePhysicalFs(m_assets), "assets");
        if (! sus) {
            LOG_ERROR("Mount assets dir failed");
            return;
        }
    }
    const auto& source_paths = source_resolution.scene_source;

    // load pkgfile
    if (! vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs(source_paths.pkg_path))) {
        LOG_INFO("load pkg file %s failed, fallback to use dir", source_paths.pkg_path.c_str());
        // load pkg dir
        if (! vfs.Mount("/assets", fs::CreatePhysicalFs(source_paths.pkg_dir))) {
            LOG_ERROR("can't load pkg directory: %s", source_paths.pkg_dir.c_str());
            return;
        }
    }
    if (! m_cache_path.empty()) {
        if (! vfs.Mount("/cache", fs::CreatePhysicalFs(m_cache_path, true), "cache")) {
            LOG_ERROR("can't load cache folder: %s", m_cache_path.c_str());
        } else {
            LOG_INFO("cache folder: %s", m_cache_path.c_str());
        }
    }

    if (! InstallVirtualAssets(vfs)) {
        LOG_ERROR("failed to install virtual assets");
        return;
    }

    {
        std::string       scene_src;
        ProjectProperties project_properties;
        const std::string base { "/assets/" };
        {
            std::string scenePath = base + source_paths.pkg_entry;
            if (vfs.Contains(scenePath)) {
                auto f = vfs.Open(scenePath);
                if (f) scene_src = f->ReadAllStr();
            }
        }
        if (scene_src.empty()) {
            LOG_ERROR("Not supported scene type");
            return;
        }
        if (! ParseProjectProperties(m_source, &project_properties, &source_error)) {
            LOG_ERROR("failed to parse project properties %s: %s",
                      m_source.c_str(),
                      source_error.c_str());
            return;
        }
        if (! m_project_property_override_json.empty()) {
            ProjectProperties override_properties;
            if (! ParseFlatProjectPropertyOverrideJson(
                    m_project_property_override_json, &override_properties, &source_error)) {
                LOG_ERROR("failed to parse project override json %s: %s",
                          m_source.c_str(),
                          source_error.c_str());
                return;
            }
            project_properties = MergeProjectProperties(project_properties, override_properties);
        }
        SceneParseRequest request {
            .scene_id           = source_paths.scene_id,
            .project_path       = m_source,
            .project_properties = &project_properties,
            .pkg_version        = ReadPkgVersionFromFile(source_paths.pkg_path),
        };
        scene = m_scene_parser.Parse(request, scene_src, vfs, *m_sound_manager);
        if (scene != nullptr && scene->runtime != nullptr) {
            scene->runtime->SetAudioResponseEnabled(m_audio_response_enabled);
            scene->runtime->SetMediaIntegrationEnabled(m_media_integration_enabled);
        }
        if (scene == nullptr) {
            LOG_ERROR("failed to parse scene: %s", m_source.c_str());
            return;
        }
        scene->vfs.swap(pVfs);
    }

    {
        auto msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCENE);
        msg->setObject("scene", scene);
        msg->post();
    }

    // draw first frame
    {
        auto msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_DRAW);
        msg->post();
    }
}

bool MainHandler::loadNonSceneProject(const ProjectManifest&   manifest,
                                      std::unique_ptr<fs::VFS> vfs) {
    switch (manifest.type) {
    case WallpaperProjectType::Video: {
        std::string error;
        auto        scene = CreateVideoProjectScene(
            std::move(vfs), std::filesystem::path(m_source), manifest, &error);
        if (scene == nullptr) {
            LOG_ERROR("failed to load video wallpaper project: %s", error.c_str());
            return false;
        }

        std::filesystem::path media_path(manifest.file);
        if (media_path.is_relative()) {
            media_path = std::filesystem::path(m_source).parent_path() / media_path;
        }
        if (auto stream = audio::CreateFfmpegSoundStream(media_path, &error, {}, true); stream != nullptr) {
            m_sound_manager->MountStream(std::move(stream));
        } else if (!error.empty()) {
            LOG_ERROR("failed to create pure-video wallpaper audio stream: %s", error.c_str());
        }

        auto msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCENE);
        msg->setObject("scene", scene);
        msg->post();

        auto draw_msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_DRAW);
        draw_msg->post();
        return true;
    }
    case WallpaperProjectType::Web:
        LOG_ERROR("web wallpaper projects are not supported: %s", manifest.file.c_str());
        return false;
    case WallpaperProjectType::Unknown:
        LOG_ERROR("unsupported wallpaper project type for %s", m_source.c_str());
        return false;
    case WallpaperProjectType::Scene:
        LOG_ERROR("scene project was routed through the non-scene project path: %s",
                  m_source.c_str());
        return false;
    }

    return false;
}

void MainHandler::sendCmdLoadScene() {
    auto self = weak_from_this().lock();
    if (self == nullptr) {
        LOG_ERROR("skip load-scene dispatch because MainHandler no longer has shared ownership");
        return;
    }
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_LOAD_SCENE);
    msg->post();
}
void MainHandler::sendFirstFrameOk() {
    auto self = weak_from_this().lock();
    if (self == nullptr) {
        LOG_ERROR("skip first-frame dispatch because MainHandler no longer has shared ownership");
        return;
    }
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_FIRST_FRAME);
    msg->post();
}

void MainHandler::sendPointerInputCapability(bool accepts_pointer_input) {
    auto self = weak_from_this().lock();
    if (self == nullptr) return;
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_POINTER_INPUT_CHANGED);
    msg->setBool("accepts_pointer_input", accepts_pointer_input);
    msg->post();
}

bool MainHandler::init() {
    if (m_inited) return true;
    m_main_loop->setName("main");
    m_render_loop->setName("render");

    if (m_main_loop->start() != looper::status_t::OK) {
        LOG_ERROR("failed to start main looper");
        return false;
    }
    if (m_render_loop->start() != looper::status_t::OK) {
        LOG_ERROR("failed to start render looper");
        m_main_loop->stop();
        return false;
    }

    if (m_main_loop->registerHandler(shared_from_this()) == looper::Handler::INVALID_HANDLER_ID) {
        LOG_ERROR("failed to register main handler");
        m_render_loop->stop();
        m_main_loop->stop();
        return false;
    }
    if (m_render_loop->registerHandler(m_render_handler) == looper::Handler::INVALID_HANDLER_ID) {
        LOG_ERROR("failed to register render handler");
        m_main_loop->unregisterHandler(id());
        m_render_loop->stop();
        m_main_loop->stop();
        return false;
    }

    {
        auto  msg        = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_DRAW);
        auto& frameTimer = m_render_handler->frame_timer;
        frameTimer.SetCallback([msg]() {
            msg->post();
        });
        frameTimer.SetRequiredFps(30);
        frameTimer.Run();
    }

    m_inited = true;
    return true;
}

void MainHandler::shutdown() {
    if (! m_inited) return;

    if (m_sound_manager->IsInited()) {
        m_sound_manager->Pause();
    }

    if (m_render_handler != nullptr) {
        m_render_handler->frame_timer.Stop();
    }

    if (m_render_loop != nullptr && m_render_handler != nullptr &&
        m_render_handler->id() != looper::Handler::INVALID_HANDLER_ID) {
        m_render_loop->unregisterHandler(m_render_handler->id());
    }
    if (m_main_loop != nullptr && id() != looper::Handler::INVALID_HANDLER_ID) {
        m_main_loop->unregisterHandler(id());
    }

    if (m_render_loop != nullptr) m_render_loop->stop();
    if (m_main_loop != nullptr) m_main_loop->stop();

    m_inited = false;
}

MainHandler::MainHandler()
    : m_sound_manager(std::make_unique<audio::SoundManager>()),
      m_main_loop(std::make_shared<looper::Looper>()),
      m_render_loop(std::make_shared<looper::Looper>()),
      m_render_handler(std::make_shared<RenderHandler>(*this)) {}
