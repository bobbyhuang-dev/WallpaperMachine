#pragma once

#include <cstdint>

namespace wallpaper::video
{

enum class YuvRange {
    /// Studio swing: 8-bit luma occupies 16..235 and chroma 16..240, so the two
    /// components have different excursions and cannot share one scale.
    Limited,
    /// Full swing: every code value is used.
    Full,
};

enum class YuvMatrix {
    Bt601,
    Bt709,
    /// Non-constant luminance only. Constant-luminance BT.2020 is a different
    /// transform and is not covered by these coefficients.
    Bt2020NonConstantLuminance,
};

/// What a decoded frame says about its own color encoding.
struct YuvColorDescription {
    YuvMatrix matrix { YuvMatrix::Bt709 };
    YuvRange  range { YuvRange::Limited };
    uint32_t  bit_depth { 8 };
    /// Set when the source carried no usable matrix and one had to be inferred,
    /// so the choice can be reported instead of silently assumed.
    bool      matrix_inferred { false };
};

/// Conversion constants in normalized [0,1] sample space, shared verbatim by
/// the CPU path and the Metal kernel so the two cannot drift apart.
///
///   luma   = (sample - y_offset) * y_scale
///   chroma = (sample - chroma_offset) * chroma_scale
struct YuvColorParams {
    float y_offset { 0.0f };
    float y_scale { 1.0f };
    float chroma_offset { 0.0f };
    float chroma_scale { 1.0f };
    float r_cr { 0.0f };
    float g_cb { 0.0f };
    float g_cr { 0.0f };
    float b_cb { 0.0f };
};

/// Chooses a matrix for a frame whose metadata is unspecified. Standard
/// definition predates BT.709, so height decides; the result is always marked
/// as inferred.
[[nodiscard]] YuvMatrix InferYuvMatrix(uint32_t width, uint32_t height);

[[nodiscard]] YuvColorParams MakeYuvColorParams(const YuvColorDescription& description);

struct Rgb8 {
    uint8_t red { 0 };
    uint8_t green { 0 };
    uint8_t blue { 0 };
};

/// Converts one 8-bit YCbCr sample triple. The reference for the CPU path and
/// for the GPU comparison tests.
[[nodiscard]] Rgb8 ConvertYuvCodeToRgb8(const YuvColorParams& params,
                                        uint8_t luma_code,
                                        uint8_t cb_code,
                                        uint8_t cr_code);

[[nodiscard]] const char* YuvMatrixName(YuvMatrix matrix);
[[nodiscard]] const char* YuvRangeName(YuvRange range);

} // namespace wallpaper::video
