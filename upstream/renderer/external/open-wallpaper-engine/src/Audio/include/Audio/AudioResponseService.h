#pragma once

#include <array>
#include <cstdint>
#include <string>

namespace wallpaper::audio
{

struct AudioSpectrumSnapshot
{
    uint64_t generation { 0 };
    uint32_t sample_rate { 12000 };
    uint32_t last_submit_sample_rate { 0 };
    uint64_t accepted_frame_count { 0 };
    std::array<float, 64> left64 {};
    std::array<float, 64> right64 {};
    std::array<float, 64> average64 {};
    std::array<float, 32> left32 {};
    std::array<float, 32> right32 {};
    std::array<float, 32> average32 {};
    std::array<float, 16> left16 {};
    std::array<float, 16> right16 {};
    std::array<float, 16> average16 {};
};

bool SubmitMonoAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error);

bool SubmitAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error);

AudioSpectrumSnapshot CurrentAudioSpectrumSnapshot();
void ResetAudioResponseServiceForTesting();

} // namespace wallpaper::audio
