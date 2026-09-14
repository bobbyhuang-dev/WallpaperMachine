#include "Audio/AudioResponseService.h"
#include "AudioResponseAnalyzerVdsp.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <iterator>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace wallpaper::audio
{
namespace
{

constexpr uint32_t kAnalysisSampleRate = 12000;
constexpr uint32_t kFftSize = 1024;
constexpr uint32_t kHopSize = 200;
constexpr size_t kInterleavedChannels = 2u;
constexpr size_t kMaxRetainedMonoFrames = static_cast<size_t>(kAnalysisSampleRate) * 2u;
constexpr auto kSnapshotStaleAfter = std::chrono::milliseconds(250);
constexpr float kSnapshotSignalFloor = 0.0001f;
constexpr float kPcmSignalFloor = 0.00005f;

struct AudioResponseState
{
    std::mutex mutex;
    std::condition_variable condition;
    std::vector<float> fifo;
    std::jthread worker;
    bool worker_started { false };
    AudioSpectrumSnapshot snapshot {};
    std::chrono::steady_clock::time_point last_submit_time {};
};

AudioResponseState g_state {};

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) {
        *error = std::move(message);
    }
    return false;
}

bool ValidateSubmitInput(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    if (sample_rate == 0) {
        return SetError(error, "sample_rate must be greater than zero");
    }
    if (sample_rate != kAnalysisSampleRate) {
        return SetError(error, "sample_rate must be 12000 Hz for audio response analysis");
    }
    if (frame_count == 0) {
        return SetError(error, "frame_count must be greater than zero");
    }
    if (pcm_frames == nullptr) {
        return SetError(error, "pcm_frames must not be null");
    }
    return true;
}

bool SnapshotHasSignal(const AudioSpectrumSnapshot& snapshot)
{
    return std::any_of(snapshot.average64.begin(), snapshot.average64.end(), [](float value) {
        return std::isfinite(value) && std::abs(value) > kSnapshotSignalFloor;
    });
}

float SanitizePcmSample(float sample)
{
    if (! std::isfinite(sample)) {
        return 0.0f;
    }
    return std::clamp(sample, -1.0f, 1.0f);
}

bool PcmBlockHasSignal(const std::array<float, kFftSize>& block)
{
    return std::any_of(block.begin(), block.end(), [](float sample) {
        return std::abs(sample) > kPcmSignalFloor;
    });
}

bool InputStreamIsStale(std::chrono::steady_clock::time_point now)
{
    return g_state.last_submit_time != std::chrono::steady_clock::time_point {} &&
           (now - g_state.last_submit_time) > kSnapshotStaleAfter;
}

void WorkerMain(std::stop_token stop_token)
{
    while (!stop_token.stop_requested()) {
        std::array<float, kFftSize> block {};
        AudioSpectrumSnapshot next_snapshot {};
        bool analyze_block { false };

        {
            std::unique_lock<std::mutex> lock(g_state.mutex);
            g_state.condition.wait_for(lock, std::chrono::milliseconds(16), [&] {
                return stop_token.stop_requested() ||
                       g_state.fifo.size() >= block.size();
            });

            if (stop_token.stop_requested()) {
                break;
            }

            const bool input_stream_is_stale = InputStreamIsStale(std::chrono::steady_clock::now());
            const bool snapshot_has_signal = SnapshotHasSignal(g_state.snapshot);

            if (input_stream_is_stale) {
                g_state.fifo.clear();
                if (g_state.snapshot.generation > 0 && snapshot_has_signal) {
                    next_snapshot = g_state.snapshot;
                    ClearAudioResponseSnapshot(&next_snapshot);
                    next_snapshot.generation += 1u;
                    next_snapshot.sample_rate = kAnalysisSampleRate;
                    next_snapshot.last_submit_sample_rate = g_state.snapshot.last_submit_sample_rate;
                    next_snapshot.accepted_frame_count = g_state.snapshot.accepted_frame_count;
                    g_state.snapshot = next_snapshot;
                }
            } else if (g_state.fifo.size() >= block.size()) {
                std::copy_n(g_state.fifo.begin(), block.size(), block.begin());
                g_state.fifo.erase(g_state.fifo.begin(), g_state.fifo.begin() + kHopSize);
                next_snapshot = g_state.snapshot;
                analyze_block = true;
            } else {
                continue;
            }
        }

        if (analyze_block) {
            if (PcmBlockHasSignal(block)) {
                AnalyzeAudioResponseMonoBlock(block.data(), kFftSize, &next_snapshot);
            } else {
                ClearAudioResponseSnapshot(&next_snapshot);
            }
            next_snapshot.generation += 1u;
            next_snapshot.sample_rate = kAnalysisSampleRate;
        }

        if (analyze_block) {
            std::lock_guard<std::mutex> lock(g_state.mutex);
            next_snapshot.last_submit_sample_rate = g_state.snapshot.last_submit_sample_rate;
            next_snapshot.accepted_frame_count = g_state.snapshot.accepted_frame_count;
            g_state.snapshot = next_snapshot;
        }
    }
}

void EnsureWorkerStartedLocked()
{
    if (g_state.worker_started) {
        return;
    }

    g_state.worker = std::jthread(WorkerMain);
    g_state.worker_started = true;
}

bool SubmitValidatedMonoFrames(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count)
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    EnsureWorkerStartedLocked();

    const auto submit_time = std::chrono::steady_clock::now();
    if (InputStreamIsStale(submit_time)) {
        g_state.fifo.clear();
    }

    const float* insert_begin = pcm_frames;
    size_t insert_count = frame_count;
    if (frame_count > kMaxRetainedMonoFrames) {
        g_state.fifo.clear();
        insert_begin = pcm_frames + (frame_count - kMaxRetainedMonoFrames);
        insert_count = kMaxRetainedMonoFrames;
    } else if (g_state.fifo.size() + frame_count > kMaxRetainedMonoFrames) {
        const size_t overflow = (g_state.fifo.size() + frame_count) - kMaxRetainedMonoFrames;
        if (overflow >= g_state.fifo.size()) {
            g_state.fifo.clear();
        } else {
            g_state.fifo.erase(g_state.fifo.begin(), g_state.fifo.begin() + static_cast<std::ptrdiff_t>(overflow));
        }
    }

    g_state.fifo.reserve(g_state.fifo.size() + insert_count);
    std::transform(
        insert_begin,
        insert_begin + insert_count,
        std::back_inserter(g_state.fifo),
        SanitizePcmSample);
    g_state.last_submit_time = submit_time;
    g_state.snapshot.last_submit_sample_rate = sample_rate;
    g_state.snapshot.accepted_frame_count += accepted_frame_count;
    g_state.condition.notify_one();
    return true;
}

} // namespace

bool SubmitMonoAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    if (!ValidateSubmitInput(sample_rate, frame_count, pcm_frames, error)) {
        return false;
    }

    return SubmitValidatedMonoFrames(sample_rate, frame_count, pcm_frames, static_cast<size_t>(frame_count));
}

bool SubmitAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    if (!ValidateSubmitInput(sample_rate, frame_count, pcm_frames, error)) {
        return false;
    }

    const size_t submitted_frame_count = static_cast<size_t>(frame_count);
    size_t retained_frame_offset = 0u;
    size_t retained_frame_count = submitted_frame_count;
    if (submitted_frame_count > kMaxRetainedMonoFrames) {
        retained_frame_offset = submitted_frame_count - kMaxRetainedMonoFrames;
        retained_frame_count = kMaxRetainedMonoFrames;
    }

    std::vector<float> mono(retained_frame_count, 0.0f);
    for (size_t frame = 0; frame < retained_frame_count; ++frame) {
        const size_t stereo_frame = retained_frame_offset + frame;
        const size_t stereo_sample = stereo_frame * kInterleavedChannels;
        mono[frame] = 0.5f * (pcm_frames[stereo_sample] + pcm_frames[stereo_sample + 1u]);
    }

    return SubmitValidatedMonoFrames(sample_rate, frame_count, mono.data(), retained_frame_count);
}

AudioSpectrumSnapshot CurrentAudioSpectrumSnapshot()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.snapshot;
}

void ResetAudioResponseServiceForTesting()
{
    std::jthread worker;
    {
        std::lock_guard<std::mutex> lock(g_state.mutex);
        worker = std::move(g_state.worker);
        g_state.worker_started = false;
        g_state.fifo.clear();
        g_state.snapshot = {};
        g_state.snapshot.sample_rate = kAnalysisSampleRate;
        g_state.last_submit_time = {};
    }

    if (worker.joinable()) {
        worker.request_stop();
        g_state.condition.notify_all();
        worker.join();
    }
}

#ifdef WESCENE_BUILD_TESTS
void StopAudioResponseWorkerAndMarkInputStaleForTesting()
{
    std::jthread worker;
    {
        std::lock_guard<std::mutex> lock(g_state.mutex);
        worker = std::move(g_state.worker);
        g_state.worker_started = false;
        if (g_state.last_submit_time != std::chrono::steady_clock::time_point {}) {
            g_state.last_submit_time = std::chrono::steady_clock::now() - kSnapshotStaleAfter - std::chrono::milliseconds(1);
        }
    }

    if (worker.joinable()) {
        worker.request_stop();
        g_state.condition.notify_all();
        worker.join();
    }
}

void SubmitStaleMonoAudioFramesToWorkerForTesting(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count)
{
    std::jthread worker;
    {
        std::lock_guard<std::mutex> lock(g_state.mutex);
        worker = std::move(g_state.worker);
        g_state.worker_started = false;
    }

    if (worker.joinable()) {
        worker.request_stop();
        g_state.condition.notify_all();
        worker.join();
    }

    {
        std::lock_guard<std::mutex> lock(g_state.mutex);
        g_state.fifo.insert(g_state.fifo.end(), pcm_frames, pcm_frames + frame_count);
        g_state.last_submit_time = std::chrono::steady_clock::now() - kSnapshotStaleAfter - std::chrono::milliseconds(1);
        g_state.snapshot.last_submit_sample_rate = sample_rate;
        g_state.snapshot.accepted_frame_count += accepted_frame_count;
        EnsureWorkerStartedLocked();
        g_state.condition.notify_one();
    }
}

size_t AudioResponseRetainedFrameCountForTesting()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.fifo.size();
}
#endif

} // namespace wallpaper::audio
