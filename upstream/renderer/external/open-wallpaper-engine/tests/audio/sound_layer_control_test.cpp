#include "WPSoundParser.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace wallpaper
{
namespace
{

class FakeSoundStream final : public audio::SoundStream {
public:
    explicit FakeSoundStream(std::vector<float> samples): m_samples(std::move(samples)) {}

    uint64_t NextPcmData(void* data, uint32_t frame_count) override {
        ++read_calls;
        const auto channel_count = static_cast<std::size_t>(std::max<uint32_t>(1, m_desc.channels));
        const auto requested_samples = static_cast<std::size_t>(frame_count) * channel_count;
        const auto remaining_samples =
            m_position < m_samples.size() ? m_samples.size() - m_position : 0;
        const auto samples_to_copy = std::min(requested_samples, remaining_samples);
        if (samples_to_copy == 0) return 0;

        std::memcpy(data, m_samples.data() + m_position, samples_to_copy * sizeof(float));
        m_position += samples_to_copy;
        return static_cast<uint64_t>(samples_to_copy / channel_count);
    }

    void PassDesc(const Desc& desc) override { m_desc = desc; }

    std::size_t position() const { return m_position; }

    int read_calls { 0 };

private:
    Desc               m_desc { .channels = 2, .sampleRate = 48'000 };
    std::vector<float> m_samples;
    std::size_t        m_position { 0 };
};

std::shared_ptr<FakeSoundStream> MakeFakeStream(std::vector<float> samples) {
    return std::make_shared<FakeSoundStream>(std::move(samples));
}

TEST(SoundLayerControlTest, StartSilentProducesSilenceAndStaysMounted) {
    auto          fake = MakeFakeStream({ 1.0f, -1.0f, 0.5f, -0.5f });
    WPSoundStream stream({ [fake](const audio::SoundStream::Desc&) {
                             return fake;
                         } },
                         { .startsilent = true });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 4> output { 9.0f, 9.0f, 9.0f, 9.0f };
    const uint64_t       frames = stream.NextPcmData(output.data(), 2);

    EXPECT_EQ(frames, 2u);
    EXPECT_FALSE(stream.IsPlaying());
    EXPECT_EQ(fake->read_calls, 0);
    for (float sample : output) {
        EXPECT_FLOAT_EQ(sample, 0.0f);
    }
}

TEST(SoundLayerControlTest, PlayPauseStopMutateNativeSoundState) {
    int           factory_calls = 0;
    WPSoundStream stream({ [&factory_calls](const audio::SoundStream::Desc&) {
                             ++factory_calls;
                             return MakeFakeStream({ 1.0f, 2.0f, 3.0f, 4.0f });
                         } },
                         { .startsilent = true });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 2> output { 0.0f, 0.0f };
    stream.Play();
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_FLOAT_EQ(output[0], 1.0f);
    EXPECT_FLOAT_EQ(output[1], 2.0f);

    stream.Pause();
    output = { 9.0f, 9.0f };
    EXPECT_FALSE(stream.IsPlaying());
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_FLOAT_EQ(output[0], 0.0f);
    EXPECT_FLOAT_EQ(output[1], 0.0f);

    stream.Play();
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_FLOAT_EQ(output[0], 3.0f);
    EXPECT_FLOAT_EQ(output[1], 4.0f);

    stream.Stop();
    EXPECT_FALSE(stream.IsPlaying());
    stream.Play();
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_EQ(factory_calls, 2);
    EXPECT_FLOAT_EQ(output[0], 1.0f);
    EXPECT_FLOAT_EQ(output[1], 2.0f);
}

TEST(SoundLayerControlTest, VolumeAndMuteAffectEmittedSamples) {
    auto          fake = MakeFakeStream({ 1.0f, -1.0f, 0.5f, -0.5f });
    WPSoundStream stream({ [fake](const audio::SoundStream::Desc&) {
                             return fake;
                         } },
                         { .volume = 0.5f });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 2> output { 0.0f, 0.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_FLOAT_EQ(output[0], 0.5f);
    EXPECT_FLOAT_EQ(output[1], -0.5f);

    stream.SetVolume(2.0f);
    EXPECT_FLOAT_EQ(stream.Volume(), 1.0f);
    stream.SetMuted(true);
    EXPECT_TRUE(stream.Muted());
    output = { 9.0f, 9.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_EQ(fake->position(), 4u);
    EXPECT_FLOAT_EQ(output[0], 0.0f);
    EXPECT_FLOAT_EQ(output[1], 0.0f);
}

TEST(SoundLayerControlTest, EmptyLoopReadProducesSilenceAndKeepsPlaying) {
    int factory_calls = 0;
    WPSoundStream stream({ [&factory_calls](const audio::SoundStream::Desc&) {
                             ++factory_calls;
                             return MakeFakeStream({});
                         } },
                         { .mode = PlaybackMode::Loop });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 4> output { 9.0f, 9.0f, 9.0f, 9.0f };

    EXPECT_EQ(stream.NextPcmData(output.data(), 2), 2u);
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_GE(factory_calls, 2);
    for (float sample : output) {
        EXPECT_FLOAT_EQ(sample, 0.0f);
    }
}

TEST(SoundLayerControlTest, ScriptTriggeredOneShotStopsAfterEnd) {
    int factory_calls = 0;
    WPSoundStream stream({ [&factory_calls](const audio::SoundStream::Desc&) {
                             ++factory_calls;
                             return MakeFakeStream({ 1.0f, -1.0f });
                         } },
                         { .startsilent = true });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    stream.Play();
    std::array<float, 2> output { 0.0f, 0.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_FLOAT_EQ(output[0], 1.0f);
    EXPECT_FLOAT_EQ(output[1], -1.0f);

    output = { 9.0f, 9.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_FALSE(stream.IsPlaying());
    EXPECT_EQ(factory_calls, 1);
    EXPECT_FLOAT_EQ(output[0], 0.0f);
    EXPECT_FLOAT_EQ(output[1], 0.0f);
}

TEST(SoundLayerControlTest, ScriptTriggeredOneShotCanReplayAfterEnd) {
    int factory_calls = 0;
    WPSoundStream stream({ [&factory_calls](const audio::SoundStream::Desc&) {
                             ++factory_calls;
                             return MakeFakeStream({ 0.75f, -0.75f });
                         } },
                         { .startsilent = true });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    stream.Play();
    std::array<float, 2> output { 0.0f, 0.0f };
    ASSERT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    ASSERT_TRUE(stream.IsPlaying());
    output = { 9.0f, 9.0f };
    ASSERT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    ASSERT_FALSE(stream.IsPlaying());

    stream.Play();
    output = { 0.0f, 0.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_EQ(factory_calls, 2);
    EXPECT_FLOAT_EQ(output[0], 0.75f);
    EXPECT_FLOAT_EQ(output[1], -0.75f);
}

TEST(SoundLayerControlTest, AuthoredLoopRestartsAfterEnd) {
    int factory_calls = 0;
    WPSoundStream stream({ [&factory_calls](const audio::SoundStream::Desc&) {
                             ++factory_calls;
                             return MakeFakeStream({ 0.25f, -0.25f });
                         } },
                         { .mode = PlaybackMode::Loop });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 2> output { 0.0f, 0.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_FLOAT_EQ(output[0], 0.25f);
    EXPECT_FLOAT_EQ(output[1], -0.25f);

    output = { 9.0f, 9.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_EQ(factory_calls, 2);
    EXPECT_FLOAT_EQ(output[0], 0.25f);
    EXPECT_FLOAT_EQ(output[1], -0.25f);
}

TEST(SoundLayerControlTest, RandomPlaybackRestartsAfterEnd) {
    int factory_calls = 0;
    WPSoundStream stream({ [&factory_calls](const audio::SoundStream::Desc&) {
                             ++factory_calls;
                             return MakeFakeStream({ 0.125f, -0.125f });
                         } },
                         { .mode = PlaybackMode::Random });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 2> output { 0.0f, 0.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_FLOAT_EQ(output[0], 0.125f);
    EXPECT_FLOAT_EQ(output[1], -0.125f);

    output = { 9.0f, 9.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_TRUE(stream.IsPlaying());
    EXPECT_EQ(factory_calls, 2);
    EXPECT_FLOAT_EQ(output[0], 0.125f);
    EXPECT_FLOAT_EQ(output[1], -0.125f);
}

TEST(SoundLayerControlTest, ParsesWallpaperEnginePlaybackModes) {
    EXPECT_EQ(ParseSoundPlaybackMode("single"), PlaybackMode::OneShot);
    EXPECT_EQ(ParseSoundPlaybackMode("random"), PlaybackMode::Random);
    EXPECT_EQ(ParseSoundPlaybackMode("loop"), PlaybackMode::Loop);
    EXPECT_EQ(ParseSoundPlaybackMode(""), PlaybackMode::Loop);
}

} // namespace
} // namespace wallpaper
