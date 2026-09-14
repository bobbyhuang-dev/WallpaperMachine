#include "AudioResponseAnalyzerVdsp.hpp"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <array>
#include <cmath>

namespace wallpaper::audio
{
namespace
{

constexpr uint32_t kFftSize = 1024;
constexpr uint32_t kBandCount64 = 64;
constexpr int kFftLog2 = 10;
constexpr float kAnalysisStepSeconds = 200.0f / 12000.0f;
constexpr float kAttackTauSeconds = 0.020f;
constexpr float kReleaseTauSeconds = 0.180f;
constexpr float kDecay = 0.88f;
constexpr float kNeighborFalloff1 = 0.72f;
constexpr float kNeighborFalloff2 = 0.42f;

struct AnalyzerResources
{
    std::array<float, kFftSize> window {};
    FFTSetup fft_setup { nullptr };

    AnalyzerResources()
    {
        vDSP_hann_window(window.data(), static_cast<vDSP_Length>(kFftSize), vDSP_HANN_NORM);
        fft_setup = vDSP_create_fftsetup(kFftLog2, FFT_RADIX2);
    }

    ~AnalyzerResources()
    {
        if (fft_setup != nullptr) {
            vDSP_destroy_fftsetup(fft_setup);
        }
    }
};

AnalyzerResources& Resources()
{
    static AnalyzerResources resources;
    return resources;
}

float EmaAlpha(float elapsed_seconds, float tau_seconds)
{
    return 1.0f - std::exp(-elapsed_seconds / tau_seconds);
}

float SmoothValue(float current, float target, uint32_t step_count)
{
    if (! std::isfinite(current)) {
        current = 0.0f;
    }
    if (! std::isfinite(target)) {
        target = 0.0f;
    }

    const float elapsed_seconds = kAnalysisStepSeconds * static_cast<float>(step_count);
    const float tau_seconds = target > current ? kAttackTauSeconds : kReleaseTauSeconds;
    const float alpha = EmaAlpha(elapsed_seconds, tau_seconds);
    return std::clamp(current + alpha * (target - current), 0.0f, 1.0f);
}

void SmoothBins(
    const std::array<float, kBandCount64>& target,
    uint32_t step_count,
    std::array<float, kBandCount64>& output)
{
    if (step_count == 0u) {
        return;
    }

    for (size_t band = 0; band < output.size(); ++band) {
        output[band] = SmoothValue(output[band], target[band], step_count);
    }
}

float WeightedMagnitude(float magnitude_squared, float band, float denominator)
{
    float log_magnitude = 0.0f;
    if (magnitude_squared > 0.0f) {
        log_magnitude = 0.35f * std::log10(magnitude_squared);
    }

    const float weight =
        2.0f - std::exp(((1.0f - (band / denominator)) * 1.0f) - 0.5f);
    return std::clamp(log_magnitude * weight, 0.0f, 1.0f);
}

float AggregateBandMagnitude(
    const std::array<float, kFftSize / 2u>& magnitudes,
    size_t band)
{
    const size_t center = band * 2u;
    const size_t begin = center > 1u ? center - 1u : 0u;
    const size_t end = std::min(magnitudes.size(), center + 4u);

    float value = 0.0f;
    for (size_t index = begin; index < end; ++index) {
        value = std::max(value, magnitudes[index]);
    }
    return value;
}

void DeriveBands(const std::array<float, 64>& source, std::array<float, 32>& target32, std::array<float, 16>& target16)
{
    target32.fill(0.0f);
    target16.fill(0.0f);

    for (size_t band = 0; band < source.size(); ++band) {
        const float value = source[band];
        const size_t index32 = band >> 1u;
        const size_t index16 = band >> 2u;
        target32[index32] = std::max(target32[index32], value);
        target16[index16] = std::max(target16[index16], value);
    }
}

void AnalyzeMono(const float* mono_pcm, std::array<float, 64>& output)
{
    const auto& resources = Resources();

    std::array<float, kFftSize> windowed {};
    std::array<DSPComplex, kFftSize / 2u> complex_input {};
    std::array<float, kFftSize / 2u> realp {};
    std::array<float, kFftSize / 2u> imagp {};
    std::array<float, kFftSize / 2u> magnitudes {};

    vDSP_vmul(
        mono_pcm,
        1,
        resources.window.data(),
        1,
        windowed.data(),
        1,
        static_cast<vDSP_Length>(kFftSize));
    for (auto& sample : windowed) {
        if (! std::isfinite(sample)) {
            sample = 0.0f;
        }
    }

    for (size_t index = 0; index < complex_input.size(); ++index) {
        complex_input[index].real = windowed[index * 2u];
        complex_input[index].imag = windowed[(index * 2u) + 1u];
    }

    DSPSplitComplex split { .realp = realp.data(), .imagp = imagp.data() };
    vDSP_ctoz(complex_input.data(), 1, &split, 1, static_cast<vDSP_Length>(complex_input.size()));
    vDSP_fft_zrip(resources.fft_setup, &split, 1, kFftLog2, FFT_FORWARD);
    vDSP_zvmags(&split, 1, magnitudes.data(), 1, static_cast<vDSP_Length>(magnitudes.size()));

    std::array<float, kBandCount64> weighted_bands {};
    for (size_t band = 0; band < weighted_bands.size(); ++band) {
        const float magnitude_squared = AggregateBandMagnitude(magnitudes, band);
        const float weighted = WeightedMagnitude(
            magnitude_squared,
            static_cast<float>(band),
            static_cast<float>(kBandCount64 - 1u));
        weighted_bands[band] = weighted;
    }

    std::array<float, kBandCount64> continuous_bands {};
    for (size_t band = 0; band < weighted_bands.size(); ++band) {
        float value = weighted_bands[band];
        if (band > 0) {
            value = std::max(value, weighted_bands[band - 1u] * kNeighborFalloff1);
        }
        if (band + 1u < weighted_bands.size()) {
            value = std::max(value, weighted_bands[band + 1u] * kNeighborFalloff1);
        }
        if (band > 1u) {
            value = std::max(value, weighted_bands[band - 2u] * kNeighborFalloff2);
        }
        if (band + 2u < weighted_bands.size()) {
            value = std::max(value, weighted_bands[band + 2u] * kNeighborFalloff2);
        }
        continuous_bands[band] = std::clamp(value, 0.0f, 1.0f);
    }

    SmoothBins(continuous_bands, 1u, output);
}

} // namespace

void AnalyzeAudioResponseMonoBlock(
    const float* mono_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot)
{
    if (mono_pcm == nullptr || snapshot == nullptr || frame_count < kFftSize) {
        return;
    }

    AnalyzeMono(mono_pcm, snapshot->average64);
    snapshot->left64 = snapshot->average64;
    snapshot->right64 = snapshot->average64;

    DeriveBands(snapshot->average64, snapshot->average32, snapshot->average16);
    snapshot->left32 = snapshot->average32;
    snapshot->right32 = snapshot->average32;
    snapshot->left16 = snapshot->average16;
    snapshot->right16 = snapshot->average16;
}

void DecayAudioResponseSnapshot(AudioSpectrumSnapshot* snapshot)
{
    if (snapshot == nullptr) {
        return;
    }

    auto decay_array = [](auto& values) {
        for (auto& value : values) {
            value *= kDecay;
        }
    };

    decay_array(snapshot->left64);
    decay_array(snapshot->right64);
    decay_array(snapshot->average64);

    DeriveBands(snapshot->average64, snapshot->average32, snapshot->average16);
    snapshot->left64 = snapshot->average64;
    snapshot->right64 = snapshot->average64;
    snapshot->left32 = snapshot->average32;
    snapshot->right32 = snapshot->average32;
    snapshot->left16 = snapshot->average16;
    snapshot->right16 = snapshot->average16;
}

void ClearAudioResponseSnapshot(AudioSpectrumSnapshot* snapshot)
{
    if (snapshot == nullptr) {
        return;
    }

    snapshot->left64.fill(0.0f);
    snapshot->right64.fill(0.0f);
    snapshot->average64.fill(0.0f);
    snapshot->left32.fill(0.0f);
    snapshot->right32.fill(0.0f);
    snapshot->average32.fill(0.0f);
    snapshot->left16.fill(0.0f);
    snapshot->right16.fill(0.0f);
    snapshot->average16.fill(0.0f);
}

#ifdef WESCENE_BUILD_TESTS
void SmoothAudioResponseBinsForTesting(
    const std::array<float, 64>& target,
    uint32_t step_count,
    std::array<float, 64>* output)
{
    if (output == nullptr) {
        return;
    }

    SmoothBins(target, step_count, *output);
}
#endif

} // namespace wallpaper::audio
