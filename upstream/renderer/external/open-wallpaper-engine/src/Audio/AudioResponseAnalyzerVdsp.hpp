#pragma once

#include "Audio/AudioResponseService.h"

#include <array>
#include <cstdint>

namespace wallpaper::audio
{

void AnalyzeAudioResponseMonoBlock(
    const float* mono_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot);

void ClearAudioResponseSnapshot(AudioSpectrumSnapshot* snapshot);
void DecayAudioResponseSnapshot(AudioSpectrumSnapshot* snapshot);

#ifdef WESCENE_BUILD_TESTS
void SmoothAudioResponseBinsForTesting(
    const std::array<float, 64>& target,
    uint32_t step_count,
    std::array<float, 64>* output);
#endif

} // namespace wallpaper::audio
