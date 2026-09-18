#pragma once
#include "SceneTexture.h"
#include "Core/Literals.hpp"

namespace wallpaper
{

struct SceneRenderTarget {
    struct Bind {
        bool        enable { false };
        std::string name {};
        bool        screen { false };
        double      scale { 1.0 };
    };

    i32           width;
    i32           height;
    /// The size this target has at render scale 1.0, i.e. the size the scene
    /// author's composition implies. Zero until the first size resolve, which
    /// latches whatever the parser produced; from then on the physical
    /// `width`/`height` above are derived from these by the internal render
    /// scale, so repeated scale changes never compound rounding.
    i32           authored_width { 0 };
    i32           authored_height { 0 };
    /// Set for targets whose size is dictated by decoded media rather than by
    /// the author's canvas. Those must not be rescaled: shrinking them only
    /// resamples a frame that was already decoded at its own resolution.
    bool          media_sized { false };
    bool          allowReuse { false };
    bool          forceClear { false };
    bool          withDepth { false };
    bool          has_mipmap { false };
    uint          mipmap_level { 1 };
    TextureSample sample { TextureWrap::CLAMP_TO_EDGE,
                           TextureWrap::CLAMP_TO_EDGE,
                           TextureFilter::LINEAR,
                           TextureFilter::LINEAR };
    Bind          bind {};
    uint32_t      sample_count { 1 };
};
} // namespace wallpaper
