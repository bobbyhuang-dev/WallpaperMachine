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
    std::condition_variable_any condition;
    // `fifo_right` is populated only while `fifo_stereo` holds; the two are
    // kept the same length so a block can always be taken from both at once.
    std::vector<float> fifo;
    std::vector<float> fifo_right;
    size_t fifo_read_offset { 0 };
    bool fifo_stereo { false };
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
           now >= g_state.last_submit_time + kSnapshotStaleAfter;
}

size_t RetainedFramesLocked()
{
    return g_state.fifo.size() - g_state.fifo_read_offset;
}

void ClearFifosLocked()
{
    g_state.fifo.clear();
    g_state.fifo_right.clear();
    g_state.fifo_read_offset = 0;
}

void DropOldestFramesLocked(size_t frame_count)
{
    if (frame_count >= RetainedFramesLocked()) {
        ClearFifosLocked();
        return;
    }
    g_state.fifo_read_offset += frame_count;
}

void PrepareFifosForAppendLocked(size_t incoming_frames)
{
    const size_t retained_frames = RetainedFramesLocked();
    if (g_state.fifo_read_offset != 0 &&
        (g_state.fifo_read_offset >= retained_frames ||
         g_state.fifo.size() + incoming_frames > kMaxRetainedMonoFrames)) {
        const auto offset = static_cast<std::ptrdiff_t>(g_state.fifo_read_offset);
        std::move(g_state.fifo.begin() + offset, g_state.fifo.end(), g_state.fifo.begin());
        g_state.fifo.resize(retained_frames);
        if (g_state.fifo_stereo) {
            std::move(g_state.fifo_right.begin() + offset, g_state.fifo_right.end(), g_state.fifo_right.begin());
            g_state.fifo_right.resize(retained_frames);
        }
        g_state.fifo_read_offset = 0;
    }

    const size_t required_size = g_state.fifo.size() + incoming_frames;
    const auto reserve = [required_size](std::vector<float>& fifo) {
        if (required_size > fifo.capacity()) {
            fifo.reserve(std::min(
                kMaxRetainedMonoFrames,
                std::max(required_size, std::max(fifo.capacity() * 2u, static_cast<size_t>(kFftSize)))));
        }
    };
    reserve(g_state.fifo);
    if (g_state.fifo_stereo) {
        reserve(g_state.fifo_right);
    }
}

void WorkerMain(std::stop_token stop_token)
{
    while (true) {
        std::array<float, kFftSize> block {};
        std::array<float, kFftSize> right_block {};
        bool block_is_stereo = false;
        AudioSpectrumSnapshot next_snapshot {};

        {
            std::unique_lock<std::mutex> lock(g_state.mutex);
            while (true) {
                if (stop_token.stop_requested()) {
                    return;
                }

                if (InputStreamIsStale(std::chrono::steady_clock::now())) {
                    ClearFifosLocked();
                    if (g_state.snapshot.generation > 0 && SnapshotHasSignal(g_state.snapshot)) {
                        next_snapshot = g_state.snapshot;
                        ClearAudioResponseSnapshot(&next_snapshot);
                        next_snapshot.generation += 1u;
                        next_snapshot.sample_rate = kAnalysisSampleRate;
                        next_snapshot.last_submit_sample_rate = g_state.snapshot.last_submit_sample_rate;
                        next_snapshot.accepted_frame_count = g_state.snapshot.accepted_frame_count;
                        g_state.snapshot = next_snapshot;
                    }
                    g_state.last_submit_time = {};
                }

                if (RetainedFramesLocked() >= block.size()) {
                    block_is_stereo = g_state.fifo_stereo;
                    const auto offset = static_cast<std::ptrdiff_t>(g_state.fifo_read_offset);
                    std::copy_n(g_state.fifo.begin() + offset, block.size(), block.begin());
                    if (block_is_stereo) {
                        std::copy_n(g_state.fifo_right.begin() + offset, right_block.size(), right_block.begin());
                    }
                    DropOldestFramesLocked(kHopSize);
                    next_snapshot = g_state.snapshot;
                    break;
                }

                const auto submitted_at = g_state.last_submit_time;
                const auto input_changed = [submitted_at] {
                    return RetainedFramesLocked() >= kFftSize ||
                           g_state.last_submit_time != submitted_at;
                };
                if (submitted_at == std::chrono::steady_clock::time_point {}) {
                    g_state.condition.wait(lock, stop_token, input_changed);
                } else {
                    g_state.condition.wait_until(
                        lock, stop_token, submitted_at + kSnapshotStaleAfter, input_changed);
                }
            }
        }

        const bool has_signal =
            PcmBlockHasSignal(block) || (block_is_stereo && PcmBlockHasSignal(right_block));
        if (has_signal) {
            if (block_is_stereo) {
                AnalyzeAudioResponseStereoBlock(
                    block.data(), right_block.data(), kFftSize, &next_snapshot);
            } else {
                AnalyzeAudioResponseMonoBlock(block.data(), kFftSize, &next_snapshot);
            }
        } else {
            ClearAudioResponseSnapshot(&next_snapshot);
            next_snapshot.stereo = block_is_stereo;
        }
        next_snapshot.generation += 1u;
        next_snapshot.sample_rate = kAnalysisSampleRate;

        {
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

bool SubmitValidatedFrames(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count,
    bool stereo)
{
    const size_t stride = stereo ? kInterleavedChannels : 1u;

    std::lock_guard<std::mutex> lock(g_state.mutex);
    EnsureWorkerStartedLocked();

    const auto submit_time = std::chrono::steady_clock::now();
    // Retained frames from the other channel layout cannot be spliced onto the
    // new one, so a layout change starts from an empty FIFO.
    if (InputStreamIsStale(submit_time) || g_state.fifo_stereo != stereo) {
        ClearFifosLocked();
    }
    g_state.fifo_stereo = stereo;

    size_t skipped_frames = 0u;
    size_t insert_count = frame_count;
    if (frame_count > kMaxRetainedMonoFrames) {
        ClearFifosLocked();
        skipped_frames = frame_count - kMaxRetainedMonoFrames;
        insert_count = kMaxRetainedMonoFrames;
    } else if (RetainedFramesLocked() + frame_count > kMaxRetainedMonoFrames) {
        DropOldestFramesLocked((RetainedFramesLocked() + frame_count) - kMaxRetainedMonoFrames);
    }

    const float* insert_begin = pcm_frames + (skipped_frames * stride);
    PrepareFifosForAppendLocked(insert_count);
    if (stereo) {
        for (size_t frame = 0; frame < insert_count; ++frame) {
            const size_t sample = frame * kInterleavedChannels;
            g_state.fifo.push_back(SanitizePcmSample(insert_begin[sample]));
            g_state.fifo_right.push_back(SanitizePcmSample(insert_begin[sample + 1u]));
        }
    } else {
        std::transform(
            insert_begin,
            insert_begin + insert_count,
            std::back_inserter(g_state.fifo),
            SanitizePcmSample);
    }

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

    return SubmitValidatedFrames(
        sample_rate, frame_count, pcm_frames, static_cast<size_t>(frame_count), false);
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

    return SubmitValidatedFrames(
        sample_rate, frame_count, pcm_frames, static_cast<size_t>(frame_count), true);
}

AudioSpectrumSnapshot CurrentAudioSpectrumSnapshot()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.snapshot;
}

bool CurrentAudioSpectrumIsStereo()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.snapshot.stereo;
}

void ResetAudioResponseServiceForTesting()
{
    std::jthread worker;
    {
        std::lock_guard<std::mutex> lock(g_state.mutex);
        worker = std::move(g_state.worker);
        g_state.worker_started = false;
        ClearFifosLocked();
        g_state.fifo_stereo = false;
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
void SetAudioSpectrumSnapshotForTesting(const AudioSpectrumSnapshot& snapshot)
{
    ResetAudioResponseServiceForTesting();
    std::lock_guard<std::mutex> lock(g_state.mutex);
    g_state.snapshot = snapshot;
}

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
        if (g_state.fifo_stereo) {
            ClearFifosLocked();
        }
        g_state.fifo_stereo = false;
        if (frame_count > kMaxRetainedMonoFrames) {
            ClearFifosLocked();
            pcm_frames += frame_count - kMaxRetainedMonoFrames;
            frame_count = kMaxRetainedMonoFrames;
        } else if (RetainedFramesLocked() + frame_count > kMaxRetainedMonoFrames) {
            DropOldestFramesLocked((RetainedFramesLocked() + frame_count) - kMaxRetainedMonoFrames);
        }
        PrepareFifosForAppendLocked(frame_count);
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
    return RetainedFramesLocked();
}
#endif

} // namespace wallpaper::audio
