#include "TexturePrefetch.hpp"

#include "CustomShaderPass.hpp"
#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "Runtime/RuntimeImageSource.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Vulkan/TextureCache.hpp"

#include <algorithm>
#include <exception>
#include <limits>

namespace wallpaper::vulkan
{

namespace
{
/// Upper estimate of an image's decoded size: RGBA8 with a full mip chain.
/// Compressed formats decode to less, which only keeps the budget cautious.
std::size_t EstimatedBytes(const ImageHeader& header) {
    const auto area = [](int32_t width, int32_t height) -> std::size_t {
        if (width <= 0 || height <= 0) return 0;
        return static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    };
    const std::size_t pixels =
        std::max(area(header.width, header.height), area(header.mapWidth, header.mapHeight));
    const std::size_t count = static_cast<std::size_t>(std::max<int32_t>(header.count, 1));
    if (pixels == 0 || pixels > std::numeric_limits<std::size_t>::max() / 16 / count) return 0;
    return count * pixels * 16 / 3;
}
} // namespace

TexturePrefetch::TexturePrefetch(IImageParser& parser, std::vector<Request> requests,
                                 std::size_t workers, std::size_t byte_budget)
    : m_parser(parser),
      m_requests(std::move(requests)),
      m_states(m_requests.size(), State::Pending),
      m_images(m_requests.size()),
      m_budget(byte_budget) {
    for (std::size_t index = 0; index < m_requests.size(); ++index) {
        m_index.emplace(m_requests[index].name, index);
    }
    workers = std::min(workers, m_requests.size());
    m_workers.reserve(workers);
    for (std::size_t worker = 0; worker < workers; ++worker) {
        // Reserved above, so only starting the thread can fail: std::thread
        // allocates its state (bad_alloc) before the OS can refuse it
        // (system_error). Unwinding here with joinable threads would
        // terminate; keep the ones that did start instead. With none, nothing
        // is admitted and preparation decodes every image itself.
        try {
            m_workers.emplace_back([this] { work(); });
        } catch (const std::exception&) {
            break;
        }
    }
}

TexturePrefetch::~TexturePrefetch() {
    {
        std::lock_guard lock(m_mutex);
        m_stop = true;
    }
    m_changed.notify_all();
    // A worker in the middle of a decode finishes that one image first.
    for (auto& worker : m_workers) worker.join();
}

std::unique_ptr<TexturePrefetch> TexturePrefetch::ForPasses(Scene& scene, const TextureCache& cache,
                                                            std::span<VulkanPass* const> passes) {
    if (scene.imageParser == nullptr) return nullptr;
    auto&       parser         = *scene.imageParser;
    const auto* runtime_images = dynamic_cast<const RuntimeImageSource*>(&parser);

    std::vector<Request> requests;
    Set<std::string>     seen;
    for (auto* pass : passes) {
        const auto* custom = dynamic_cast<const CustomShaderPass*>(pass);
        if (custom == nullptr || custom->prepared()) continue;
        for (const auto& name : custom->desc().textures) {
            if (name.empty() || IsSpecTex(name) || ! seen.insert(name).second) continue;
            if (runtime_images != nullptr && runtime_images->IsRuntimeImage(name)) continue;
            const auto texture = scene.textures.find(name);
            if (texture == scene.textures.end() || texture->second.isVideo ||
                texture->second.isSprite) {
                continue;
            }
            if (cache.FindTex(name).has_value()) continue;
            const ImageHeader header = parser.ParseHeader(name);
            if (header.isVideo || header.isSprite) continue;
            const std::size_t estimate = EstimatedBytes(header);
            if (estimate == 0) continue;
            requests.push_back(Request { .name = name, .estimated_bytes = estimate });
        }
    }
    if (requests.size() < 2) return nullptr;

    // One core stays with the preparing thread, which uploads what these decode.
    const std::size_t hardware = std::max(2u, std::thread::hardware_concurrency());
    const std::size_t workers  = std::clamp<std::size_t>(hardware - 1, 1, kMaxWorkers);
    return std::make_unique<TexturePrefetch>(parser, std::move(requests), workers);
}

std::optional<std::shared_ptr<Image>> TexturePrefetch::Take(std::string_view name) {
    std::unique_lock lock(m_mutex);
    const auto found = m_index.find(name);
    if (found == m_index.end()) return std::nullopt;
    const std::size_t index = found->second;
    if (index < m_consumed) return std::nullopt;

    for (std::size_t skipped = m_consumed; skipped < index; ++skipped) release(skipped);
    m_consumed = index + 1;
    if (index >= m_next) {
        // Not admitted yet. Waiting would leave preparation behind the budget,
        // so the caller decodes it and admission resumes after it.
        m_states[index] = State::Done;
        m_next          = index + 1;
        m_changed.notify_all();
        return std::nullopt;
    }

    m_changed.wait(lock, [&] { return m_states[index] != State::Decoding; });
    std::optional<std::shared_ptr<Image>> result;
    if (m_states[index] == State::Ready) {
        result = std::move(m_images[index]);
        m_reserved -= m_requests[index].estimated_bytes;
        m_states[index] = State::Done;
    }
    m_changed.notify_all();
    return result;
}

void TexturePrefetch::release(std::size_t index) {
    switch (m_states[index]) {
    case State::Pending: m_states[index] = State::Done; break;
    case State::Decoding: m_states[index] = State::Abandoned; break;
    case State::Ready:
        m_images[index].reset();
        m_reserved -= m_requests[index].estimated_bytes;
        m_states[index] = State::Done;
        break;
    case State::Abandoned:
    case State::Done: break;
    }
}

void TexturePrefetch::work() {
    std::unique_lock lock(m_mutex);
    for (;;) {
        m_changed.wait(lock, [&] {
            if (m_stop || m_next >= m_requests.size()) return true;
            const std::size_t cost = m_requests[m_next].estimated_bytes;
            return m_reserved == 0 || cost <= m_budget - std::min(m_reserved, m_budget);
        });
        if (m_stop || m_next >= m_requests.size()) return;

        const std::size_t index = m_next++;
        if (m_states[index] != State::Pending) continue;
        m_states[index] = State::Decoding;
        m_reserved += m_requests[index].estimated_bytes;
        lock.unlock();

        std::shared_ptr<Image> image;
        bool                   decoded = true;
        try {
            image = m_parser.Parse(m_requests[index].name);
        } catch (const std::exception&) {
            // Left to the preparing thread, which reports its own failure.
            decoded = false;
        }

        lock.lock();
        if (m_states[index] == State::Decoding && decoded) {
            m_images[index] = std::move(image);
            m_states[index] = State::Ready;
        } else {
            m_reserved -= m_requests[index].estimated_bytes;
            m_states[index] = State::Done;
        }
        m_changed.notify_all();
        if (image != nullptr) {
            // An abandoned image is freed without holding up the other workers.
            lock.unlock();
            image.reset();
            lock.lock();
        }
    }
}

} // namespace wallpaper::vulkan
