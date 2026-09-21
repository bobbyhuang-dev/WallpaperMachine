#pragma once

#include "Interface/IImageParser.h"

#include <atomic>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>

namespace wallpaper
{

class RuntimeImageSource final : public IImageParser {
public:
    explicit RuntimeImageSource(std::unique_ptr<IImageParser> fallback)
        : m_fallback(std::move(fallback)) {
        std::array<uint8_t, 4> transparent_pixel { 0, 0, 0, 0 };
        // Both cover slots exist before any track does: a layer that binds one
        // of them must find an image on the very first parse, and a wallpaper
        // with media integration off never gets a second chance to be told.
        SetRgbaImage("$mediaThumbnail", 1, 1, transparent_pixel.data(), transparent_pixel.size());
        SetRgbaImage(
            "$mediaPreviousThumbnail", 1, 1, transparent_pixel.data(), transparent_pixel.size());
    }

    std::shared_ptr<Image> Parse(const std::string& name) override {
        {
            std::lock_guard lock(m_mutex);
            if (auto iterator = m_runtime_images.find(name); iterator != m_runtime_images.end()) {
                return iterator->second;
            }
        }
        return m_fallback != nullptr ? m_fallback->Parse(name) : nullptr;
    }

    ImageHeader ParseHeader(const std::string& name) override {
        {
            std::lock_guard lock(m_mutex);
            if (auto iterator = m_runtime_images.find(name); iterator != m_runtime_images.end()) {
                return iterator->second->header;
            }
        }
        return m_fallback != nullptr ? m_fallback->ParseHeader(name) : ImageHeader {};
    }

    bool IsRuntimeImage(const std::string& name) const {
        std::lock_guard lock(m_mutex);
        return m_runtime_images.find(name) != m_runtime_images.end();
    }

    /// How many times this name has been given new pixels, or zero when it
    /// never has.
    ///
    /// Monotonic per name and readable without taking a copy of the image, so a
    /// renderer can ask "is what I uploaded still current?" every frame without
    /// hashing pixels. The same number is what `Image::key` carries, so the two
    /// can never disagree.
    uint64_t Version(const std::string& name) const {
        std::lock_guard lock(m_mutex);
        const auto iterator = m_versions.find(name);
        return iterator == m_versions.end() ? 0 : iterator->second;
    }

    /// Whether `name` already holds exactly these pixels.
    ///
    /// Republishing an identical image is not free and not neutral: it retires
    /// the texture the GPU is sampling, allocates and uploads another, and —
    /// for a cover — moves the current image into `$mediaPreviousThumbnail`,
    /// which is what a wallpaper cross-fades *from*, so a replay would fade a
    /// cover into itself. Replays are normal: every new scene handle is sent
    /// the current cover again. One comparison against bytes already in memory
    /// is cheaper than any of that.
    bool MatchesRgba(const std::string& name, uint32_t width, uint32_t height,
                     const uint8_t* rgba, std::size_t rgba_len) const {
        if (rgba == nullptr) return false;
        std::lock_guard lock(m_mutex);
        const auto iterator = m_runtime_images.find(name);
        if (iterator == m_runtime_images.end() || iterator->second == nullptr) return false;
        const auto& image = *iterator->second;
        if (image.header.format != TextureFormat::RGBA8) return false;
        if (image.header.width != static_cast<int32_t>(width) ||
            image.header.height != static_cast<int32_t>(height)) {
            return false;
        }
        if (image.slots.empty() || image.slots.front().mipmaps.empty()) return false;
        const auto& mip = image.slots.front().mipmaps.front();
        if (mip.data == nullptr || mip.size < 0) return false;
        if (static_cast<std::size_t>(mip.size) != rgba_len) return false;
        return std::memcmp(mip.data.get(), rgba, rgba_len) == 0;
    }

    void SetRgbaImage(std::string name, uint32_t width, uint32_t height, const uint8_t* rgba,
                      std::size_t rgba_len) {
        if (name.empty() || width == 0 || height == 0 || rgba == nullptr) return;
        if (width > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
            height > static_cast<uint32_t>(std::numeric_limits<int32_t>::max())) {
            return;
        }

        const std::size_t pixel_count = static_cast<std::size_t>(width) * height;
        if (pixel_count > std::numeric_limits<std::size_t>::max() / 4) return;

        const std::size_t expected_len = pixel_count * 4;
        if (rgba_len != expected_len) return;

        const auto version             = m_next_version.fetch_add(1, std::memory_order_relaxed) + 1;
        auto       image               = std::make_shared<Image>();
        image->key                     = name + "#" + std::to_string(version);
        image->header.width            = static_cast<int32_t>(width);
        image->header.height           = static_cast<int32_t>(height);
        image->header.mapWidth         = static_cast<int32_t>(width);
        image->header.mapHeight        = static_cast<int32_t>(height);
        image->header.count            = 1;
        image->header.format           = TextureFormat::RGBA8;
        image->header.sample.wrapS     = TextureWrap::CLAMP_TO_EDGE;
        image->header.sample.wrapT     = TextureWrap::CLAMP_TO_EDGE;
        image->header.sample.minFilter = TextureFilter::LINEAR;
        image->header.sample.magFilter = TextureFilter::LINEAR;
        image->header.extraHeader["compo1"].val = 1;
        image->header.extraHeader["compo2"].val = 1;
        image->header.extraHeader["compo3"].val = 1;

        Image::Slot slot;
        slot.width  = static_cast<int32_t>(width);
        slot.height = static_cast<int32_t>(height);

        ImageData mip;
        mip.width  = slot.width;
        mip.height = slot.height;
        mip.size   = static_cast<isize>(expected_len);
        mip.data   = ImageDataPtr(new uint8_t[expected_len], [](uint8_t* data) {
            delete[] data;
        });
        std::memcpy(mip.data.get(), rgba, expected_len);
        slot.mipmaps.push_back(std::move(mip));
        image->slots.push_back(std::move(slot));

        std::lock_guard lock(m_mutex);
        if (name == "$mediaThumbnail") {
            const auto previous = m_runtime_images.find(name);
            const bool cleared  = width == 1 && height == 1 && rgba[3] == 0;
            // Keep the outgoing cover's image and version together. The new
            // version belongs to the pixels being published now; stamping it
            // onto the previous slot made Version() disagree with Image::key.
            if (!cleared && previous != m_runtime_images.end()) {
                const auto old_version              = m_versions.find(name);
                m_runtime_images["$mediaPreviousThumbnail"] = previous->second;
                m_versions["$mediaPreviousThumbnail"] =
                    old_version == m_versions.end() ? 0 : old_version->second;
            } else {
                m_runtime_images["$mediaPreviousThumbnail"] = image;
                m_versions["$mediaPreviousThumbnail"]       = version;
            }
        }
        m_versions[name]                  = version;
        m_runtime_images[std::move(name)] = std::move(image);
    }

    /// Publishes what `from` currently holds under `to`, without copying pixels.
    ///
    /// `SetRgbaImage` builds a fresh immutable `Image` every time, so two names
    /// may share one: replacing `from` afterwards leaves `to` holding exactly
    /// what `from` used to be. `to` inherits `from`'s version so the number and
    /// the `Image::key` it is taken from keep agreeing, and it still only ever
    /// rises because `from`'s own version does.
    ///
    /// Returns false when `from` has never been given pixels.
    bool AliasRuntimeImage(const std::string& from, const std::string& to) {
        std::lock_guard lock(m_mutex);
        const auto iterator = m_runtime_images.find(from);
        if (iterator == m_runtime_images.end()) return false;
        m_runtime_images[to] = iterator->second;
        m_versions[to]       = m_versions[from];
        return true;
    }

private:
    mutable std::mutex                                      m_mutex;
    std::unique_ptr<IImageParser>                           m_fallback;
    std::unordered_map<std::string, std::shared_ptr<Image>> m_runtime_images;
    std::unordered_map<std::string, uint64_t>               m_versions;
    std::atomic<uint64_t>                                   m_next_version { 0 };
};

/// Publishes one now-playing cover, and reports whether anything changed.
///
/// The cover being replaced becomes `$mediaPreviousThumbnail`, which is what a
/// wallpaper cross-fades from, so it has to be captured before the new pixels
/// land. One definition, because the renderer and the offscreen probe must
/// publish covers the same way.
///
/// Returns false when the cover on screen is already exactly this one, so a
/// caller can skip the work a change would have needed.
inline bool PublishSystemMediaArtwork(RuntimeImageSource& source, uint32_t width, uint32_t height,
                                      const uint8_t* rgba, std::size_t rgba_len) {
    if (source.MatchesRgba("$mediaThumbnail", width, height, rgba, rgba_len)) return false;
    source.AliasRuntimeImage("$mediaThumbnail", "$mediaPreviousThumbnail");
    source.SetRgbaImage("$mediaThumbnail", width, height, rgba, rgba_len);
    return true;
}

} // namespace wallpaper
