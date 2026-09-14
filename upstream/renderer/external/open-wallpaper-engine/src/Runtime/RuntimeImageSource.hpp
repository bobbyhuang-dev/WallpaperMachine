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
        SetRgbaImage("$mediaThumbnail", 1, 1, transparent_pixel.data(), transparent_pixel.size());
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
        m_runtime_images[std::move(name)] = std::move(image);
    }

private:
    mutable std::mutex                                      m_mutex;
    std::unique_ptr<IImageParser>                           m_fallback;
    std::unordered_map<std::string, std::shared_ptr<Image>> m_runtime_images;
    std::atomic<uint64_t>                                   m_next_version { 0 };
};

} // namespace wallpaper
