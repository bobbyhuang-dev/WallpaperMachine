#pragma once

#include "Core/MapSet.hpp"
#include "Core/NoCopyMove.hpp"

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace wallpaper
{
class IImageParser;
class Scene;
struct Image;

namespace vulkan
{
class TextureCache;
class VulkanPass;

/// Decodes the images a pass preparation is about to parse, ahead of it and on
/// several threads. A scene whose startup is dozens of large embedded PNGs is
/// otherwise held to one core for as long as they take. Only the CPU decode
/// moves: uploads, their order and the texture cache stay with the preparing
/// thread.
///
/// Images being decoded or waiting to be taken are held under a byte budget
/// estimated from each texture's header, and are admitted strictly in the
/// order they will be asked for. Preparation never waits for an image that has
/// not been admitted -- it decodes that one itself -- so the budget can slow
/// the prefetch down but cannot block preparation.
class TexturePrefetch : NoCopy, NoMove {
public:
    struct Request {
        std::string name;
        std::size_t estimated_bytes { 0 };
    };

    /// Decoded pixels the prefetch may hold ahead of preparation. A single
    /// image larger than this is still admitted alone.
    static constexpr std::size_t kByteBudget = 256u * 1024u * 1024u;
    static constexpr std::size_t kMaxWorkers = 6;

    TexturePrefetch(IImageParser& parser, std::vector<Request> requests, std::size_t workers,
                    std::size_t byte_budget = kByteBudget);
    ~TexturePrefetch();

    /// Plans the images the unprepared passes will parse, in the order they
    /// will parse them, and starts decoding. Skips render targets, runtime
    /// images, videos and anything already uploaded, and sprite sheets, whose
    /// header describes one frame rather than the sheet the budget must cover.
    /// Null when fewer than two images qualify, since one image gains nothing
    /// from another thread.
    static std::unique_ptr<TexturePrefetch> ForPasses(Scene& scene, const TextureCache& cache,
                                                      std::span<VulkanPass* const> passes);

    /// The parse result for `name` -- possibly null when the image failed to
    /// decode -- waiting while it is still being decoded. Nothing when it was
    /// never scheduled, not yet admitted or already taken; the caller then
    /// parses it itself. Asking for one gives up every earlier image not yet
    /// taken: preparation asks in schedule order, so those were skipped.
    std::optional<std::shared_ptr<Image>> Take(std::string_view name);

private:
    enum class State : uint8_t {
        Pending,
        Decoding,
        Ready,
        /// Given up while a worker was decoding it; the worker releases it.
        Abandoned,
        /// Taken, skipped, released or failed: no longer available.
        Done,
    };

    void work();
    /// Gives up `index`. Requires the lock.
    void release(std::size_t index);

    IImageParser&                        m_parser;
    std::vector<Request>                 m_requests;
    std::vector<State>                   m_states;
    std::vector<std::shared_ptr<Image>>  m_images;
    Map<std::string, std::size_t>        m_index;
    std::size_t                          m_budget;
    /// Next request to admit; everything before it was admitted or skipped.
    std::size_t                          m_next { 0 };
    /// Every request before this one has been taken or given up.
    std::size_t                          m_consumed { 0 };
    std::size_t                          m_reserved { 0 };
    bool                                 m_stop { false };
    std::mutex                           m_mutex;
    std::condition_variable              m_changed;
    std::vector<std::thread>             m_workers;
};

} // namespace vulkan
} // namespace wallpaper
