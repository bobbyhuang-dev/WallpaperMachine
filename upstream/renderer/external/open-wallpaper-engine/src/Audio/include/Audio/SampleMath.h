#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace wallpaper::audio
{

inline float ClampVolume(float value) {
    if (! std::isfinite(value)) return 1.0f;
    return std::clamp(value, 0.0f, 1.0f);
}

inline void ClearInterleavedF32(void* output, std::size_t sample_count) {
    auto* samples = static_cast<float*>(output);
    std::fill_n(samples, sample_count, 0.0f);
}

inline void ApplyVolumeF32(void* data, std::size_t sample_count, float volume) {
    auto*       samples        = static_cast<float*>(data);
    const float clamped_volume = ClampVolume(volume);
    for (std::size_t index = 0; index < sample_count; ++index) {
        samples[index] *= clamped_volume;
    }
}

inline void MixInterleavedF32(void* output, const void* input, std::size_t sample_count,
                              float volume) {
    auto*       output_samples = static_cast<float*>(output);
    const auto* input_samples  = static_cast<const float*>(input);
    const float clamped_volume = ClampVolume(volume);
    for (std::size_t index = 0; index < sample_count; ++index) {
        output_samples[index] += input_samples[index] * clamped_volume;
    }
}

} // namespace wallpaper::audio
