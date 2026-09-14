#include "Audio/SoundManager.h"
#include "Audio/FfmpegSoundStream.hpp"
#include "miniaudio-wrapper.hpp"
#include "Fs/IBinaryStream.h"
#include "Core/Literals.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

using namespace wallpaper;
using namespace wallpaper::audio;

class Channel_Impl : public miniaudio::Channel {
public:
    explicit Channel_Impl(std::shared_ptr<SoundStream> ss): m_ss(std::move(ss)) {}
    ~Channel_Impl() override { StopWorker(); }

    ma_uint64 NextPcmData(void* pData, ma_uint32 frameCount) override {
        const auto channel_count = m_desc.phyChannels;
        if (pData == nullptr || frameCount == 0 || channel_count == 0) return frameCount;

        const auto requested_samples = static_cast<std::size_t>(frameCount) * channel_count;
        audio::ClearInterleavedF32(pData, requested_samples);

        std::unique_lock<std::mutex> lock { m_mutex, std::try_to_lock };
        if (! lock.owns_lock() || m_ring.empty()) return frameCount;

        const auto frames_to_copy =
            std::min<std::size_t>(frameCount, BufferedFramesLocked());
        ReadFramesLocked(static_cast<float*>(pData), frames_to_copy);
        lock.unlock();
        m_cv.notify_one();
        return frameCount;
    }

    void PassDeviceDesc(const miniaudio::DeviceDesc& desc) override {
        StopWorker();
        m_ss->PassDesc({ .channels = desc.phyChannels, .sampleRate = desc.sampleRate });
        {
            std::lock_guard<std::mutex> lock { m_mutex };
            m_desc = desc;
            m_read_frame = 0;
            m_buffered_frames = 0;
            const auto capacity_frames = BufferCapacityFrames(desc);
            m_ring.assign(static_cast<std::size_t>(capacity_frames) * desc.phyChannels, 0.0f);
        }
        if (desc.phyChannels != 0 && desc.sampleRate != 0) StartWorker();
    }

private:
    static ma_uint32 BufferCapacityFrames(const miniaudio::DeviceDesc& desc) {
        if (desc.sampleRate == 0) return 0;
        return std::max<ma_uint32>(desc.sampleRate / 2, 2048);
    }

    static ma_uint32 DecodeChunkFrames(const miniaudio::DeviceDesc& desc) {
        if (desc.sampleRate == 0) return 512;
        return std::max<ma_uint32>(512, std::min<ma_uint32>(desc.sampleRate / 50, 2048));
    }

    void StartWorker() {
        {
            std::lock_guard<std::mutex> lock { m_mutex };
            m_stop_worker = false;
        }
        m_worker = std::thread([this] {
            WorkerLoop();
        });
    }

    void StopWorker() {
        {
            std::lock_guard<std::mutex> lock { m_mutex };
            m_stop_worker = true;
        }
        m_cv.notify_all();
        if (m_worker.joinable()) m_worker.join();
    }

    void WorkerLoop() {
        while (true) {
            miniaudio::DeviceDesc desc {};
            ma_uint32             frames_to_decode = 0;
            {
                std::unique_lock<std::mutex> lock { m_mutex };
                m_cv.wait(lock, [this] {
                    return m_stop_worker || FreeFramesLocked() >= DecodeChunkFrames(m_desc);
                });
                if (m_stop_worker) return;
                desc = m_desc;
                frames_to_decode = std::min<ma_uint32>(
                    DecodeChunkFrames(desc),
                    static_cast<ma_uint32>(FreeFramesLocked()));
            }

            if (desc.phyChannels == 0 || frames_to_decode == 0) continue;

            std::vector<float> decoded(
                static_cast<std::size_t>(frames_to_decode) * desc.phyChannels,
                0.0f);
            uint64_t frames_read = m_ss->NextPcmData(decoded.data(), frames_to_decode);
            if (frames_read == 0) frames_read = frames_to_decode;
            frames_read = std::min<uint64_t>(frames_read, frames_to_decode);

            {
                std::lock_guard<std::mutex> lock { m_mutex };
                if (m_stop_worker) return;
                WriteFramesLocked(decoded.data(), static_cast<std::size_t>(frames_read));
            }
            m_cv.notify_all();
        }
    }

    std::size_t CapacityFramesLocked() const {
        if (m_desc.phyChannels == 0) return 0;
        return m_ring.size() / m_desc.phyChannels;
    }

    std::size_t BufferedFramesLocked() const { return m_buffered_frames; }

    std::size_t FreeFramesLocked() const {
        return CapacityFramesLocked() - BufferedFramesLocked();
    }

    void ReadFramesLocked(float* output, std::size_t frame_count) {
        const auto channel_count = static_cast<std::size_t>(m_desc.phyChannels);
        const auto capacity = CapacityFramesLocked();
        for (std::size_t copied = 0; copied < frame_count;) {
            const auto frames_until_wrap = capacity - m_read_frame;
            const auto frames_now = std::min(frame_count - copied, frames_until_wrap);
            std::memcpy(
                output + copied * channel_count,
                m_ring.data() + m_read_frame * channel_count,
                frames_now * channel_count * sizeof(float));
            m_read_frame = (m_read_frame + frames_now) % capacity;
            copied += frames_now;
            m_buffered_frames -= frames_now;
        }
    }

    void WriteFramesLocked(const float* input, std::size_t frame_count) {
        const auto channel_count = static_cast<std::size_t>(m_desc.phyChannels);
        const auto capacity = CapacityFramesLocked();
        const auto frames_to_write = std::min(frame_count, FreeFramesLocked());
        std::size_t write_frame = (m_read_frame + m_buffered_frames) % capacity;
        for (std::size_t written = 0; written < frames_to_write;) {
            const auto frames_until_wrap = capacity - write_frame;
            const auto frames_now = std::min(frames_to_write - written, frames_until_wrap);
            std::memcpy(
                m_ring.data() + write_frame * channel_count,
                input + written * channel_count,
                frames_now * channel_count * sizeof(float));
            write_frame = (write_frame + frames_now) % capacity;
            written += frames_now;
            m_buffered_frames += frames_now;
        }
    }

    miniaudio::DeviceDesc        m_desc;
    std::shared_ptr<SoundStream> m_ss;
    std::mutex                   m_mutex;
    std::condition_variable      m_cv;
    std::thread                  m_worker;
    std::vector<float>           m_ring;
    std::size_t                  m_read_frame { 0 };
    std::size_t                  m_buffered_frames { 0 };
    bool                         m_stop_worker { false };
};

std::unique_ptr<SoundStream>
wallpaper::audio::CreateSoundStream(std::shared_ptr<wallpaper::fs::IBinaryStream> stream,
                                    const SoundStream::Desc&                      desc,
                                    SoundStream::Options options) {
    std::string error;
    auto        sound_stream = CreateFfmpegSoundStream(std::move(stream), &error, options);
    if (sound_stream == nullptr) {
        LOG_ERROR("failed to create FFmpeg sound stream: %s", error.c_str());
        return nullptr;
    }
    sound_stream->PassDesc(desc);
    return sound_stream;
}

class SoundManager::impl : NoCopy, NoMove {
public:
    impl(): device() {};
    ~impl() = default;
    miniaudio::Device device {};
};

SoundManager::SoundManager(): pImpl(std::make_unique<impl>()) {}
SoundManager::~SoundManager() {}

void SoundManager::MountStream(std::unique_ptr<SoundStream>&& ss) {
    MountStream(std::shared_ptr<SoundStream>(std::move(ss)));
}

void SoundManager::MountStream(std::shared_ptr<SoundStream> ss) {
    pImpl->device.MountChannel(std::make_unique<Channel_Impl>(std::move(ss)));
}

bool SoundManager::Init() { return pImpl->device.Init({}); }
bool SoundManager::IsInited() const { return pImpl->device.IsInited(); }
void SoundManager::Play() { pImpl->device.Start(); }
void SoundManager::Pause() { pImpl->device.Stop(); }

void  SoundManager::UnMountAll() { pImpl->device.UnmountAll(); }
float SoundManager::Volume() const { return pImpl->device.Volume(); }

bool SoundManager::Muted() const { return pImpl->device.Muted(); }
void SoundManager::SetMuted(bool v) {
    pImpl->device.SetMuted(v);
    if (! pImpl->device.IsInited()) {
        if (! Init()) {
            LOG_ERROR("can't init sound device after mute state change");
        }
    }
}
void SoundManager::SetVolume(float v) { pImpl->device.SetVolume(v); }
