#include "Audio/SampleMath.h"

#include <gtest/gtest.h>

#include <array>
#include <limits>

namespace wallpaper::audio
{
namespace
{

TEST(AudioSampleMathTest, ClampVolumeRejectsInvalidValues) {
    EXPECT_FLOAT_EQ(ClampVolume(-0.25f), 0.0f);
    EXPECT_FLOAT_EQ(ClampVolume(0.5f), 0.5f);
    EXPECT_FLOAT_EQ(ClampVolume(1.25f), 1.0f);
    EXPECT_FLOAT_EQ(ClampVolume(std::numeric_limits<float>::infinity()), 1.0f);
    EXPECT_FLOAT_EQ(ClampVolume(std::numeric_limits<float>::quiet_NaN()), 1.0f);
}

TEST(AudioSampleMathTest, ClearInterleavedF32WritesSilence) {
    std::array<float, 6> output { 1.0f, -1.0f, 0.5f, 0.25f, -0.5f, 2.0f };

    ClearInterleavedF32(output.data(), output.size());

    for (float sample : output) {
        EXPECT_FLOAT_EQ(sample, 0.0f);
    }
}

TEST(AudioSampleMathTest, ApplyVolumeF32ScalesSamplesInPlace) {
    std::array<float, 4> samples { 1.0f, -1.0f, 0.5f, -0.5f };

    ApplyVolumeF32(samples.data(), samples.size(), 0.5f);

    EXPECT_FLOAT_EQ(samples[0], 0.5f);
    EXPECT_FLOAT_EQ(samples[1], -0.5f);
    EXPECT_FLOAT_EQ(samples[2], 0.25f);
    EXPECT_FLOAT_EQ(samples[3], -0.25f);
}

TEST(AudioSampleMathTest, MixInterleavedF32AddsScaledInput) {
    std::array<float, 4> output { 0.25f, 0.25f, -0.25f, -0.25f };
    std::array<float, 4> input { 1.0f, -1.0f, 0.5f, -0.5f };

    MixInterleavedF32(output.data(), input.data(), input.size(), 0.5f);

    EXPECT_FLOAT_EQ(output[0], 0.75f);
    EXPECT_FLOAT_EQ(output[1], -0.25f);
    EXPECT_FLOAT_EQ(output[2], 0.0f);
    EXPECT_FLOAT_EQ(output[3], -0.5f);
}

} // namespace
} // namespace wallpaper::audio
