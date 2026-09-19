#pragma once

// Objective-C++ only: this header names Metal types and is included from `.mm`
// translation units. The part of the video decision that plain C++ needs is in
// `MetalRender/MetalVideoSupport.hpp`.

#import <Metal/Metal.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper
{
class Scene;
class RendererCounters;

namespace video
{
class VideoTextureSource;
}

namespace metal
{

/// The scene's video textures, as ordinary sampled `MTLTexture`s.
///
/// This is not the plain-video backend and does not replace it: it exists so a
/// scene whose author samples a video the way it samples any other texture can
/// stay on the native Metal renderer. Each texture keeps its own decoder and
/// its own playback semantics, exactly as the compatibility backend's texture
/// cache gives it.
///
/// One frame is imported per generation, no matter how many passes sample it,
/// and every object that frame's texture depends on — the pixel buffer, the
/// Core Video wrappers, the conversion destination — stays retained until the
/// command buffer that read it completes.
class MetalVideoTextures {
public:
    MetalVideoTextures();
    ~MetalVideoTextures();
    MetalVideoTextures(const MetalVideoTextures&)            = delete;
    MetalVideoTextures& operator=(const MetalVideoTextures&) = delete;

    void configure(id<MTLDevice> device);

    /// Graph compile time. One source per key; keys that are not video
    /// textures are ignored. False with an error means the whole scene falls
    /// back to the compatibility backend.
    bool prepare(Scene& scene, const std::vector<std::string>& texture_keys, std::string* error);

    /// Drops the sources and the textures. Frames a command buffer may still be
    /// reading are kept alive by that command buffer's completion handler, not
    /// by this object, so calling this mid-flight is safe.
    void release();

    [[nodiscard]] bool owns(const std::string& key) const;
    [[nodiscard]] bool empty() const;

    void setPaused(bool paused);
    void setRate(float rate);
    void setCounters(RendererCounters* counters);

    /// Shortest frame period among the sources, in seconds, or 0 when any of
    /// them cannot say — pacing on the others would skip its changes.
    [[nodiscard]] double shortestFramePeriod() const;

    /// True when at least one source is unpaused with a positive rate: the
    /// scene must not idle, because its content changes without an event.
    [[nodiscard]] bool advancesOnItsOwn() const;

    /// Render thread, once per frame, before any pass is encoded into
    /// `command`. Conversions are encoded into `command`, so ordering against
    /// the passes that sample them comes from the command buffer itself.
    bool beginFrame(Scene& scene, id<MTLCommandBuffer> command, std::string* error);

    /// Last valid frame for `key`, at the decoded frame's own size. Nil only
    /// when no frame was ever produced for it.
    [[nodiscard]] id<MTLTexture> texture(const std::string& key) const;

#ifdef WESCENE_BUILD_TESTS
    /// Registers a source directly, so the import, the conversion and the
    /// lifetime rules can be exercised without any media on disk.
    bool prepareForTests(const std::string&                         key,
                         std::shared_ptr<video::VideoTextureSource> source,
                         std::string*                               error);
    [[nodiscard]] std::uint64_t conversionsEncodedForTests() const;
    [[nodiscard]] std::uint64_t importsForTests() const;
#endif

private:
    struct State;
    /// Shared with every frame this object has in flight. A completion handler
    /// holds its own reference and never touches `this`, which is what makes a
    /// handler that runs after `release()` — or after destruction, on whatever
    /// thread Metal picks — well defined.
    std::shared_ptr<State> m_state;
};

} // namespace metal
} // namespace wallpaper
