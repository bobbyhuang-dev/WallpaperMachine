#include "Audio/AudioResponseService.h"
#include "Audio/AudioResponseAnalyzerVdsp.hpp"

#include <gtest/gtest.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <new>
#include <string>
#include <thread>
#include <vector>

namespace
{

std::atomic<bool> g_track_allocations { false };
std::atomic<std::size_t> g_largest_allocation { 0u };

void TrackAllocation(std::size_t size)
{
    if (!g_track_allocations.load(std::memory_order_relaxed)) {
        return;
    }

    std::size_t current = g_largest_allocation.load(std::memory_order_relaxed);
    while (current < size &&
           !g_largest_allocation.compare_exchange_weak(
               current,
               size,
               std::memory_order_relaxed,
               std::memory_order_relaxed)) {
    }
}

struct AllocationTrackingScope
{
    AllocationTrackingScope()
    {
        g_largest_allocation.store(0u, std::memory_order_relaxed);
        g_track_allocations.store(true, std::memory_order_relaxed);
    }

    ~AllocationTrackingScope()
    {
        g_track_allocations.store(false, std::memory_order_relaxed);
    }
};

} // namespace

void* operator new(std::size_t size)
{
    TrackAllocation(size);
    if (void* pointer = std::malloc(size)) {
        return pointer;
    }
    throw std::bad_alloc();
}

void* operator new[](std::size_t size)
{
    TrackAllocation(size);
    if (void* pointer = std::malloc(size)) {
        return pointer;
    }
    throw std::bad_alloc();
}

void operator delete(void* pointer) noexcept
{
    std::free(pointer);
}

void operator delete[](void* pointer) noexcept
{
    std::free(pointer);
}

void operator delete(void* pointer, std::size_t) noexcept
{
    std::free(pointer);
}

void operator delete[](void* pointer, std::size_t) noexcept
{
    std::free(pointer);
}

namespace wallpaper::audio
{

void StopAudioResponseWorkerAndMarkInputStaleForTesting();
void SubmitStaleMonoAudioFramesToWorkerForTesting(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count);
size_t AudioResponseRetainedFrameCountForTesting();

namespace
{

constexpr uint32_t kSubmitSampleRate = 12'000u;
constexpr uint32_t kChunkFrameCount = 200u;
constexpr uint32_t kChunkSubmitCount = 6u;
constexpr uint32_t kRetainedFrameCapacity = kSubmitSampleRate * 2u;
constexpr float kAnalysisStepSeconds = 200.0f / 12000.0f;
constexpr float kAttackTauSeconds = 0.020f;

AudioSpectrumSnapshot WaitForGeneration() {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);

    while (std::chrono::steady_clock::now() < deadline) {
        auto snapshot = CurrentAudioSpectrumSnapshot();
        if (snapshot.generation > 0u) {
            return snapshot;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    return CurrentAudioSpectrumSnapshot();
}

bool HasNonZeroAverage64Bin(const AudioSpectrumSnapshot& snapshot) {
    for (const float bin : snapshot.average64) {
        if (bin != 0.0f) {
            return true;
        }
    }
    return false;
}

AudioSpectrumSnapshot WaitForSilentGeneration(uint64_t generation) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1000);

    while (std::chrono::steady_clock::now() < deadline) {
        auto snapshot = CurrentAudioSpectrumSnapshot();
        if (snapshot.generation > generation && !HasNonZeroAverage64Bin(snapshot)) {
            return snapshot;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    return CurrentAudioSpectrumSnapshot();
}

AudioSpectrumSnapshot WaitForGenerationAfter(uint64_t generation, std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;

    while (std::chrono::steady_clock::now() < deadline) {
        auto snapshot = CurrentAudioSpectrumSnapshot();
        if (snapshot.generation > generation) {
            return snapshot;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    return CurrentAudioSpectrumSnapshot();
}

float MaxAbsDifference(const std::array<float, 64>& lhs, const std::array<float, 64>& rhs) {
    float difference = 0.0f;
    for (std::size_t index = 0; index < lhs.size(); ++index) {
        difference = std::max(difference, std::abs(lhs[index] - rhs[index]));
    }
    return difference;
}

std::array<float, 64> SmoothInSteps(const std::array<float, 64>& target, uint32_t steps_per_call, uint32_t call_count) {
    std::array<float, 64> output {};
    for (uint32_t call = 0; call < call_count; ++call) {
        SmoothAudioResponseBinsForTesting(target, steps_per_call, &output);
    }
    return output;
}

TEST(AudioResponseMonoTest, MonoSubmitUpdatesSnapshotAt12Khz) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 200> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = std::sin(static_cast<float>(index) * 0.05f);
    }

    std::string error;
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(samples.size()), samples.data(), &error))
            << error;
    }

    auto snapshot = WaitForGeneration();
    EXPECT_EQ(snapshot.sample_rate, 12'000u);
    EXPECT_EQ(snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(snapshot.accepted_frame_count, samples.size() * kChunkSubmitCount);
    EXPECT_GT(snapshot.generation, 0u);
    EXPECT_TRUE(HasNonZeroAverage64Bin(snapshot));
    EXPECT_EQ(snapshot.left64, snapshot.average64);
    EXPECT_EQ(snapshot.right64, snapshot.average64);
    EXPECT_EQ(snapshot.left32, snapshot.average32);
    EXPECT_EQ(snapshot.right32, snapshot.average32);
    EXPECT_EQ(snapshot.left16, snapshot.average16);
    EXPECT_EQ(snapshot.right16, snapshot.average16);
}

TEST(AudioResponseMonoTest, AnalyzerSmoothingIsIndependentOfStepGrouping) {
    std::array<float, 64> target {};
    for (std::size_t index = 0; index < target.size(); ++index) {
        target[index] = 1.0f - (static_cast<float>(index) / static_cast<float>(target.size() * 2u));
    }

    std::array<float, 64> one_step {};
    SmoothAudioResponseBinsForTesting(target, 1u, &one_step);

    const auto many_small_steps = SmoothInSteps(target, 1u, 12u);
    const auto fewer_large_steps = SmoothInSteps(target, 3u, 4u);
    const float expected_one_step = 1.0f - std::exp(-kAnalysisStepSeconds / kAttackTauSeconds);
    const float expected_twelve_steps = 1.0f - std::exp(-(kAnalysisStepSeconds * 12.0f) / kAttackTauSeconds);

    EXPECT_NEAR(one_step.front(), expected_one_step, 0.00001f);
    EXPECT_NEAR(many_small_steps.front(), expected_twelve_steps, 0.00001f);
    EXPECT_LT(MaxAbsDifference(many_small_steps, fewer_large_steps), 0.00001f);
    EXPECT_GT(many_small_steps.front(), 0.99f);
}

TEST(AudioResponseMonoTest, StaleSnapshotPublishesSilenceInsteadOfReusingOldBins) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 200> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = std::sin(static_cast<float>(index) * 0.05f);
    }

    std::string error;
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(samples.size()), samples.data(), &error))
            << error;
    }

    const auto live_snapshot = WaitForGeneration();
    ASSERT_GT(live_snapshot.generation, 0u);
    ASSERT_TRUE(HasNonZeroAverage64Bin(live_snapshot));

    const auto stale_snapshot = WaitForSilentGeneration(live_snapshot.generation);
    EXPECT_GT(stale_snapshot.generation, live_snapshot.generation);
    EXPECT_FALSE(HasNonZeroAverage64Bin(stale_snapshot));
    EXPECT_EQ(stale_snapshot.left64, stale_snapshot.average64);
    EXPECT_EQ(stale_snapshot.right64, stale_snapshot.average64);
    EXPECT_EQ(stale_snapshot.left32, stale_snapshot.average32);
    EXPECT_EQ(stale_snapshot.right32, stale_snapshot.average32);
    EXPECT_EQ(stale_snapshot.left16, stale_snapshot.average16);
    EXPECT_EQ(stale_snapshot.right16, stale_snapshot.average16);
}

TEST(AudioResponseMonoTest, NonFiniteSamplesAreTreatedAsSilence) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 200> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = index % 2u == 0u ? std::numeric_limits<float>::quiet_NaN()
                                          : std::numeric_limits<float>::infinity();
    }

    std::string error;
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(samples.size()), samples.data(), &error))
            << error;
    }

    const auto snapshot = WaitForGeneration();
    EXPECT_GT(snapshot.generation, 0u);
    EXPECT_FALSE(HasNonZeroAverage64Bin(snapshot));
    EXPECT_EQ(snapshot.left64, snapshot.average64);
    EXPECT_EQ(snapshot.right64, snapshot.average64);
}

TEST(AudioResponseMonoTest, ContinuousSilenceAfterSignalClearsSnapshot) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 200> signal {};
    for (std::size_t index = 0; index < signal.size(); ++index) {
        signal[index] = std::sin(static_cast<float>(index) * 0.05f);
    }

    std::string error;
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(signal.size()), signal.data(), &error))
            << error;
    }

    const auto live_snapshot = WaitForGeneration();
    ASSERT_GT(live_snapshot.generation, 0u);
    ASSERT_TRUE(HasNonZeroAverage64Bin(live_snapshot));

    std::array<float, 200> silence {};
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(silence.size()), silence.data(), &error))
            << error;
    }

    const auto silent_snapshot = WaitForSilentGeneration(live_snapshot.generation);
    EXPECT_GT(silent_snapshot.generation, live_snapshot.generation);
    EXPECT_FALSE(HasNonZeroAverage64Bin(silent_snapshot));
    EXPECT_EQ(silent_snapshot.left64, silent_snapshot.average64);
    EXPECT_EQ(silent_snapshot.right64, silent_snapshot.average64);
}

TEST(AudioResponseMonoTest, ResumeAfterStaleDoesNotAnalyzeRetainedOldSamples) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 200> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = std::sin(static_cast<float>(index) * 0.05f);
    }

    std::string error;
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(samples.size()), samples.data(), &error))
            << error;
    }

    const auto live_snapshot = WaitForGeneration();
    ASSERT_GT(live_snapshot.generation, 0u);
    ASSERT_TRUE(HasNonZeroAverage64Bin(live_snapshot));

    const auto stale_snapshot = WaitForSilentGeneration(live_snapshot.generation);
    ASSERT_GT(stale_snapshot.generation, live_snapshot.generation);
    ASSERT_FALSE(HasNonZeroAverage64Bin(stale_snapshot));

    std::array<float, 1024> fresh_samples {};
    for (std::size_t index = 0; index < fresh_samples.size(); ++index) {
        fresh_samples[index] = 0.05f * std::sin(static_cast<float>(index) * 0.08f);
    }
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(fresh_samples.size()), fresh_samples.data(), &error))
        << error;

    const auto resumed_snapshot = WaitForGenerationAfter(stale_snapshot.generation, std::chrono::milliseconds(500));
    ASSERT_GT(resumed_snapshot.generation, stale_snapshot.generation);

    ResetAudioResponseServiceForTesting();

    error.clear();
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(fresh_samples.size()), fresh_samples.data(), &error))
        << error;

    const auto fresh_only_snapshot = WaitForGeneration();
    ASSERT_GT(fresh_only_snapshot.generation, 0u);

    EXPECT_LT(MaxAbsDifference(resumed_snapshot.average64, fresh_only_snapshot.average64), 0.00001f);
}

TEST(AudioResponseMonoTest, StalePartialFifoBeforeFirstBlockIsNotMixedIntoResume) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 1000> stale_samples {};
    for (std::size_t index = 0; index < stale_samples.size(); ++index) {
        stale_samples[index] = std::sin(static_cast<float>(index) * 0.75f);
    }

    std::array<float, 1024> fresh_samples {};
    for (std::size_t index = 0; index < fresh_samples.size(); ++index) {
        fresh_samples[index] = 0.05f * std::sin(static_cast<float>(index) * 0.08f);
    }

    std::string error;
    ASSERT_TRUE(SubmitMonoAudioFrames(
        kSubmitSampleRate,
        static_cast<uint32_t>(stale_samples.size()),
        stale_samples.data(),
        &error))
        << error;

    StopAudioResponseWorkerAndMarkInputStaleForTesting();

    ASSERT_TRUE(SubmitMonoAudioFrames(
        kSubmitSampleRate,
        static_cast<uint32_t>(fresh_samples.size()),
        fresh_samples.data(),
        &error))
        << error;

    const auto resumed_snapshot = WaitForGeneration();
    ASSERT_GT(resumed_snapshot.generation, 0u);

    ResetAudioResponseServiceForTesting();

    error.clear();
    ASSERT_TRUE(SubmitMonoAudioFrames(
        kSubmitSampleRate,
        static_cast<uint32_t>(fresh_samples.size()),
        fresh_samples.data(),
        &error))
        << error;

    const auto fresh_only_snapshot = WaitForGeneration();
    ASSERT_GT(fresh_only_snapshot.generation, 0u);

    EXPECT_LT(MaxAbsDifference(resumed_snapshot.average64, fresh_only_snapshot.average64), 0.00001f);
}

TEST(AudioResponseMonoTest, WorkerClearsStaleFullFifoBeforeAnalysis) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 1024> stale_samples {};
    for (std::size_t index = 0; index < stale_samples.size(); ++index) {
        stale_samples[index] = std::sin(static_cast<float>(index) * 0.09f);
    }

    SubmitStaleMonoAudioFramesToWorkerForTesting(
        kSubmitSampleRate,
        static_cast<uint32_t>(stale_samples.size()),
        stale_samples.data(),
        stale_samples.size());

    const auto snapshot = WaitForGenerationAfter(0u, std::chrono::milliseconds(500));
    EXPECT_EQ(snapshot.generation, 0u);
    EXPECT_FALSE(HasNonZeroAverage64Bin(snapshot));
    EXPECT_EQ(AudioResponseRetainedFrameCountForTesting(), 0u);
    EXPECT_EQ(snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(snapshot.accepted_frame_count, stale_samples.size());
}

TEST(AudioResponseMonoTest, SixtyFourBinFrameInputsPopulateAllSpectrumResolutions) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 64> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = std::sin(static_cast<float>(index) * 0.15f);
    }

    std::string error;
    for (uint32_t submit = 0; submit < 20u; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(
            kSubmitSampleRate,
            static_cast<uint32_t>(samples.size()),
            samples.data(),
            &error))
            << error;
    }

    auto snapshot = WaitForGeneration();
    EXPECT_GT(snapshot.generation, 0u);
    EXPECT_TRUE(HasNonZeroAverage64Bin(snapshot));
    EXPECT_EQ(snapshot.left16, snapshot.average16);
    EXPECT_EQ(snapshot.right16, snapshot.average16);
    EXPECT_EQ(snapshot.left32, snapshot.average32);
    EXPECT_EQ(snapshot.right32, snapshot.average32);
    EXPECT_EQ(snapshot.left64, snapshot.average64);
    EXPECT_EQ(snapshot.right64, snapshot.average64);
}

TEST(AudioResponseMonoTest, MonoSubmitRejectsInvalidInput) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 200> samples {};
    std::string error;

    EXPECT_FALSE(SubmitMonoAudioFrames(0, kChunkFrameCount, samples.data(), &error));
    EXPECT_NE(error.find("sample_rate"), std::string::npos);

    error.clear();
    EXPECT_FALSE(SubmitMonoAudioFrames(kSubmitSampleRate, 0, samples.data(), &error));
    EXPECT_NE(error.find("frame_count"), std::string::npos);

    error.clear();
    EXPECT_FALSE(SubmitMonoAudioFrames(kSubmitSampleRate, kChunkFrameCount, nullptr, &error));
    EXPECT_NE(error.find("pcm_frames"), std::string::npos);
}

TEST(AudioResponseMonoTest, MonoSubmitRejectsNonAnalysisSampleRate) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 200> samples {};
    std::string error;

    EXPECT_FALSE(SubmitMonoAudioFrames(48'000u, kChunkFrameCount, samples.data(), &error));
    EXPECT_NE(error.find("sample_rate"), std::string::npos);
    EXPECT_NE(error.find("12000"), std::string::npos);
}

TEST(AudioResponseMonoTest, OversizedMonoSubmitIsAcceptedAndAnalyzed) {
    ResetAudioResponseServiceForTesting();

    constexpr uint32_t oversized_frame_count = 24'200u;
    std::vector<float> samples(oversized_frame_count, 0.0f);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = std::sin(static_cast<float>(index) * 0.03f);
    }

    std::string error;
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, oversized_frame_count, samples.data(), &error))
        << error;

    auto snapshot = WaitForGeneration();
    EXPECT_EQ(snapshot.sample_rate, 12'000u);
    EXPECT_EQ(snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(snapshot.accepted_frame_count, oversized_frame_count);
    EXPECT_GT(snapshot.generation, 0u);
    EXPECT_TRUE(HasNonZeroAverage64Bin(snapshot));
}

TEST(AudioResponseMonoTest, StereoCompatibilityWrapperDownmixesToMono) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 400> stereo {};
    for (std::size_t frame = 0; frame < 200; ++frame) {
        stereo[frame * 2u] = 0.25f;
        stereo[(frame * 2u) + 1u] = 0.75f;
    }

    std::string error;
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitAudioFrames(kSubmitSampleRate, kChunkFrameCount, stereo.data(), &error))
            << error;
    }

    auto stereo_snapshot = WaitForGeneration();

    ResetAudioResponseServiceForTesting();

    std::array<float, 200> mono {};
    mono.fill(0.5f);

    error.clear();
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, kChunkFrameCount, mono.data(), &error))
            << error;
    }

    auto mono_snapshot = WaitForGeneration();
    EXPECT_EQ(stereo_snapshot.sample_rate, 12'000u);
    EXPECT_EQ(stereo_snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(stereo_snapshot.accepted_frame_count, kChunkFrameCount * kChunkSubmitCount);
    EXPECT_GT(stereo_snapshot.generation, 0u);
    EXPECT_EQ(mono_snapshot.sample_rate, 12'000u);
    EXPECT_EQ(mono_snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(mono_snapshot.accepted_frame_count, kChunkFrameCount * kChunkSubmitCount);
    EXPECT_GT(mono_snapshot.generation, 0u);
    EXPECT_EQ(stereo_snapshot.average64, mono_snapshot.average64);
    EXPECT_EQ(stereo_snapshot.left64, stereo_snapshot.average64);
    EXPECT_EQ(stereo_snapshot.right64, stereo_snapshot.average64);
    EXPECT_EQ(mono_snapshot.left64, mono_snapshot.average64);
    EXPECT_EQ(mono_snapshot.right64, mono_snapshot.average64);
}

TEST(AudioResponseMonoTest, OversizedStereoSubmitDownmixesOnlyRetainedSamples) {
    ResetAudioResponseServiceForTesting();

    constexpr uint32_t oversized_frame_count = kRetainedFrameCapacity + 400u;
    std::vector<float> stereo(static_cast<std::size_t>(oversized_frame_count) * 2u, 0.0f);
    std::vector<float> retained_mono(kRetainedFrameCapacity, 0.0f);

    for (uint32_t frame = 0; frame < oversized_frame_count; ++frame) {
        const float left = frame < 400u ? 0.0f : std::sin(static_cast<float>(frame) * 0.03f);
        const float right = frame < 400u ? 0.0f : std::cos(static_cast<float>(frame) * 0.04f);
        const std::size_t stereo_index = static_cast<std::size_t>(frame) * 2u;
        stereo[stereo_index] = left;
        stereo[stereo_index + 1u] = right;

        if (frame >= oversized_frame_count - kRetainedFrameCapacity) {
            retained_mono[frame - (oversized_frame_count - kRetainedFrameCapacity)] = 0.5f * (left + right);
        }
    }

    std::string error;
    {
        AllocationTrackingScope allocation_tracking;
        ASSERT_TRUE(SubmitAudioFrames(kSubmitSampleRate, oversized_frame_count, stereo.data(), &error))
            << error;
    }

    auto stereo_snapshot = WaitForGeneration();
    EXPECT_EQ(stereo_snapshot.sample_rate, 12'000u);
    EXPECT_EQ(stereo_snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(stereo_snapshot.accepted_frame_count, oversized_frame_count);
    EXPECT_GT(stereo_snapshot.generation, 0u);
    EXPECT_TRUE(HasNonZeroAverage64Bin(stereo_snapshot));
    EXPECT_LT(g_largest_allocation.load(std::memory_order_relaxed), static_cast<std::size_t>(oversized_frame_count) * sizeof(float));

    ResetAudioResponseServiceForTesting();

    error.clear();
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, kRetainedFrameCapacity, retained_mono.data(), &error))
        << error;

    auto mono_snapshot = WaitForGeneration();
    EXPECT_GT(mono_snapshot.generation, 0u);
    EXPECT_EQ(stereo_snapshot.average64, mono_snapshot.average64);
}

TEST(AudioResponseMonoTest, StereoCompatibilityWrapperRejectsNonAnalysisSampleRate) {
    ResetAudioResponseServiceForTesting();

    std::array<float, 400> stereo {};
    std::string error;

    EXPECT_FALSE(SubmitAudioFrames(48'000u, kChunkFrameCount, stereo.data(), &error));
    EXPECT_NE(error.find("sample_rate"), std::string::npos);
    EXPECT_NE(error.find("12000"), std::string::npos);
}

} // namespace
} // namespace wallpaper::audio
