#include "Video/VideoColorConversion.hpp"

#include <algorithm>
#include <cmath>

namespace wallpaper::video
{
namespace
{

/// Derived from the luma coefficients Kr/Kb of each matrix:
///   r_cr = 2(1 - Kr), b_cb = 2(1 - Kb),
///   g_cb = -2 Kb (1 - Kb) / Kg, g_cr = -2 Kr (1 - Kr) / Kg.
struct MatrixCoefficients {
    float r_cr;
    float g_cb;
    float g_cr;
    float b_cb;
};

constexpr MatrixCoefficients CoefficientsFor(YuvMatrix matrix)
{
    switch (matrix) {
    case YuvMatrix::Bt709:
        return { 1.5748f, -0.187324f, -0.468124f, 1.8556f };
    case YuvMatrix::Bt2020NonConstantLuminance:
        return { 1.4746f, -0.164553f, -0.571353f, 1.8814f };
    case YuvMatrix::Bt601:
        break;
    }
    return { 1.402f, -0.344136f, -0.714136f, 1.772f };
}

uint8_t QuantizeUnitToCode(float value)
{
    const float clamped = std::clamp(value, 0.0f, 1.0f);
    return static_cast<uint8_t>(std::lround(clamped * 255.0f));
}

} // namespace

YuvMatrix InferYuvMatrix(uint32_t width, uint32_t height)
{
    // Anything at or below standard-definition height is treated as BT.601;
    // everything larger as BT.709. Width guards anamorphic SD sources whose
    // height alone would look like HD.
    const bool standard_definition = height <= 576 && width <= 1024;
    return standard_definition ? YuvMatrix::Bt601 : YuvMatrix::Bt709;
}

YuvColorParams MakeYuvColorParams(const YuvColorDescription& description)
{
    const uint32_t bit_depth = std::clamp(description.bit_depth, 8u, 16u);
    const float    maximum_code = static_cast<float>((1u << bit_depth) - 1u);
    // Studio-swing footroom and the chroma midpoint scale with bit depth.
    const float    depth_scale = static_cast<float>(1u << (bit_depth - 8u));
    const float    chroma_midpoint = 128.0f * depth_scale;

    const MatrixCoefficients coefficients = CoefficientsFor(description.matrix);
    YuvColorParams params {};
    params.r_cr = coefficients.r_cr;
    params.g_cb = coefficients.g_cb;
    params.g_cr = coefficients.g_cr;
    params.b_cb = coefficients.b_cb;
    params.chroma_offset = chroma_midpoint / maximum_code;

    if (description.range == YuvRange::Full) {
        params.y_offset = 0.0f;
        params.y_scale = 1.0f;
        // Full-swing chroma still centres on the midpoint, but spans the whole
        // code range rather than 224 code values.
        params.chroma_scale = maximum_code / (255.0f * depth_scale);
        return params;
    }

    params.y_offset = 16.0f * depth_scale / maximum_code;
    params.y_scale = maximum_code / (219.0f * depth_scale);
    // The chroma excursion is 224 code values, not 219 and not the full range:
    // reusing the luma scale, or treating chroma as `sample - 0.5`, desaturates
    // and shifts every limited-range frame.
    params.chroma_scale = maximum_code / (224.0f * depth_scale);
    return params;
}

Rgb8 ConvertYuvCodeToRgb8(const YuvColorParams& params,
                          uint8_t luma_code,
                          uint8_t cb_code,
                          uint8_t cr_code)
{
    const float luma =
        std::clamp((static_cast<float>(luma_code) / 255.0f - params.y_offset) * params.y_scale,
                   0.0f, 1.0f);
    const float cb =
        (static_cast<float>(cb_code) / 255.0f - params.chroma_offset) * params.chroma_scale;
    const float cr =
        (static_cast<float>(cr_code) / 255.0f - params.chroma_offset) * params.chroma_scale;

    return Rgb8 {
        .red = QuantizeUnitToCode(luma + params.r_cr * cr),
        .green = QuantizeUnitToCode(luma + params.g_cb * cb + params.g_cr * cr),
        .blue = QuantizeUnitToCode(luma + params.b_cb * cb),
    };
}

const char* YuvMatrixName(YuvMatrix matrix)
{
    switch (matrix) {
    case YuvMatrix::Bt601: return "BT.601";
    case YuvMatrix::Bt709: return "BT.709";
    case YuvMatrix::Bt2020NonConstantLuminance: return "BT.2020 NCL";
    }
    return "unknown";
}

const char* YuvRangeName(YuvRange range)
{
    return range == YuvRange::Full ? "full" : "limited";
}

} // namespace wallpaper::video
