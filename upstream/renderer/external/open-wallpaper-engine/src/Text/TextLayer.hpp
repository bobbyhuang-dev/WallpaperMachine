#pragma once

#include <Eigen/Dense>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{

class SharedFontData {
public:
    using const_iterator = std::vector<uint8_t>::const_iterator;

    SharedFontData() = default;
    SharedFontData(std::vector<uint8_t> data) {
        if (! data.empty()) {
            m_data = std::make_shared<std::vector<uint8_t>>(std::move(data));
        }
    }
    SharedFontData(const SharedFontData&) noexcept            = default;
    SharedFontData(SharedFontData&&) noexcept                 = default;
    SharedFontData& operator=(const SharedFontData&) noexcept = default;
    SharedFontData& operator=(SharedFontData&&) noexcept      = default;

    SharedFontData& operator=(std::vector<uint8_t> data) {
        m_data.reset();
        if (! data.empty()) {
            m_data = std::make_shared<std::vector<uint8_t>>(std::move(data));
        }
        return *this;
    }

    bool empty() const { return storage().empty(); }
    std::size_t size() const { return storage().size(); }
    const uint8_t* data() const { return storage().data(); }
    const std::vector<uint8_t>& bytes() const { return storage(); }
    const_iterator begin() const { return storage().begin(); }
    const_iterator end() const { return storage().end(); }

private:
    const std::vector<uint8_t>& storage() const {
        static const std::vector<uint8_t> empty;
        return m_data == nullptr ? empty : *m_data;
    }

    std::shared_ptr<const std::vector<uint8_t>> m_data;
};

struct TextLayerState {
    std::string          text;
    std::string          layer_key;
    std::string          font_key;
    std::string          resolved_font_kind { "family" };
    std::string          resolved_font_identity;
    std::string          resolved_font_path;
    SharedFontData       resolved_font_data;
    float                point_size { 12.0f };
    float                padding { 0.0f };
    Eigen::Vector2f      explicit_size { Eigen::Vector2f::Zero() };
    Eigen::Vector3f      color { Eigen::Vector3f::Ones() };
    float                alpha { 1.0f };
    float                brightness { 1.0f };
    std::string          horizontal_align;
    std::string          vertical_align;
    std::string          anchor;
    bool                 dirty { false };
    bool                 cache_dirty { false };
    bool                 full_dirty { false };
    bool                 layout_pending { false };
    uint64_t             cache_revision { 0 };
    std::string          texture_cache_key;
    std::string          render_backend { "runtime-rgba-texture" };
    Eigen::Vector2f      layout_size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f      raster_size { Eigen::Vector2f::Zero() };
};

struct TextLayerRenderBounds {
    float left { 0.0f };
    float right { 0.0f };
    float bottom { 0.0f };
    float top { 0.0f };
};

struct TextLayerRenderFrame {
    TextLayerRenderBounds bounds;
    Eigen::Vector2f       size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f       center { Eigen::Vector2f::Zero() };
};

struct TextLayerTextureBounds {
    float left { 0.0f };
    float right { 1.0f };
    float bottom { 1.0f };
    float top { 0.0f };
};

class TextLayer {
public:
    explicit TextLayer(TextLayerState state);

    const TextLayerState& state() const { return m_state; }
    const std::string&    text() const { return m_state.text; }
    Eigen::Vector2f       size() const { return m_state.layout_size; }
    Eigen::Vector2f       rasterSize() const;
    TextLayerRenderBounds renderBounds() const;
    bool                  dirty() const { return m_state.dirty; }
    bool                  layoutPending() const { return m_state.layout_pending; }

    void SetText(std::string text);
    void ApplyPreparedLayout(Eigen::Vector2f layout_size, Eigen::Vector2f raster_size);
    void ClearDirty();

private:
    void Relayout();
    void EnsureCacheIdentity();
    void MarkCacheDirty();

    TextLayerState m_state;
};

Eigen::Vector2f EstimateTextLayerSize(std::string_view text, float point_size, float padding);
Eigen::Vector2f MeasureTextLayerSize(const TextLayerState& state);
Eigen::Vector2f TextLayerLayoutSize(const TextLayerState& state);
Eigen::Vector2f TextLayerRasterSize(const TextLayerState& state);
TextLayerRenderBounds TextLayerRenderBoundsForRasterSize(const TextLayerState& state,
                                                         Eigen::Vector2f raster_size);
TextLayerRenderFrame TextLayerRenderFrameForRasterSize(const TextLayerState& state,
                                                       Eigen::Vector2f raster_size);
TextLayerRenderFrame TextLayerRenderFrameForCapacity(const TextLayerState& state,
                                                     Eigen::Vector2f raster_size,
                                                     Eigen::Vector2f capacity_size);
TextLayerRenderFrame TextLayerRenderFrameForTargetExtent(const TextLayerRenderFrame& frame,
                                                         Eigen::Vector2f target_extent);
TextLayerRenderFrame TextLayerRenderFrameClampedToTarget(const TextLayerRenderFrame& frame,
                                                         const TextLayerRenderFrame& target);
TextLayerTextureBounds TextLayerTextureBoundsForRenderTarget(const TextLayerRenderFrame& frame,
                                                             Eigen::Vector2f target_size,
                                                             Eigen::Vector2f target_center);
std::string     TextTextureName(std::string_view layer_key);
void            RasterizeTextLayer(const TextLayerState& state, uint32_t width, uint32_t height,
                                   std::vector<uint8_t>& rgba);
#ifdef WESCENE_BUILD_TESTS
uint64_t        TextLayerMeasurementCountForTests();
void            ResetTextLayerMeasurementCountForTests();
#endif

} // namespace wallpaper
