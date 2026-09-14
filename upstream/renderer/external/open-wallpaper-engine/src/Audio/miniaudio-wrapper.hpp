#pragma once
#include <memory>
#include <vector>
#include <mutex>
#include <cstdint>
#include <algorithm>
#include <functional>
#include <cstring>
#include <atomic>
#include <utility>

#include "Utils/Logging.h"
#include "Core/NoCopyMove.hpp"
#include "Audio/SampleMath.h"

#define MA_NO_WASAPI
#define MA_NO_DSOUND
#define MA_NO_WINMM
#define MA_NO_ENCODING
#define MINIAUDIO_IMPLEMENTATION
#include <miniaudio.h>

namespace miniaudio
{

struct DeviceDesc {
    ma_uint32              phyChannels;
    ma_uint32              sampleRate;
    static const ma_format format { ma_format_f32 };
};

class Channel : NoCopy {
public:
    Channel()          = default;
    virtual ~Channel() = default;

    virtual ma_uint64 NextPcmData(void* pData, ma_uint32 frameCount) = 0;
    virtual void      PassDeviceDesc(const DeviceDesc&)              = 0;
};

class Device : NoCopy {
public:
    Device() {}
    ~Device() { UnInit(); }
    Device(Device&& o) noexcept: m_device(std::exchange(o.m_device, ma_device())) {}
    Device& operator=(Device&& o) noexcept {
        m_device = std::exchange(o.m_device, ma_device());
        return *this;
    }

public:
    bool Init(const DeviceDesc& d) {
        if (IsInited()) return true; // already inited
        ma_result result;
        auto      config = GenMaDeviceConfig(d);
        Stop();
        result = ma_device_init(NULL, &config, &m_device);
        if (result == MA_SUCCESS) {
            LOG_INFO("sound device inited");
        }
        if (result != MA_SUCCESS || ! IsInited()) {
            LOG_ERROR("can't init sound device");
            UnInit();
            return false;
        }
        if (m_device.playback.format != ma_format_f32) {
            LOG_ERROR("wrong playback format");
            UnInit();
            return false;
        }
        if (ma_device_start(&m_device) != MA_SUCCESS) {
            LOG_ERROR("can't start sound device");
            UnInit();
            return false;
        }
        {
            std::unique_lock<std::mutex> lock { m_mutex };
            for (auto& el : m_channels) {
                el.chn->PassDeviceDesc(GetDesc());
            }
        }
        Start();
        return true;
    }
    bool IsInited() const { return m_device.state.value != ma_device_state_uninitialized; }
    void UnInit() {
        if (IsInited()) {
            LOG_INFO("uninit sound device");
        }
        UnmountAll();
        ma_device_uninit(&m_device); // always do it
    }
    // bool IsStarted() const { return ma_device_is_started(&m_device); }
    // bool IsStopped() const { return ma_device_get_state(&m_device) == MA_STATE_STOPPED; }
    void Start() {
        m_running.store(true, std::memory_order_relaxed);
        /*
        if(!IsStopped()) return;
        LOG_INFO("state: %d", ma_device_get_state(&m_device));
        if (ma_device_start(&m_device) != MA_SUCCESS) {
            LOG_ERROR("can't start sound device");
            //ma_device_uninit(&m_device);
        }
        */
    }
    void Stop() {
        m_running.store(false, std::memory_order_relaxed);
        /*
        if(!IsStarted()) return;
        LOG_INFO("state: %d", ma_device_get_state(&m_device));
        if(ma_device_stop(&m_device) != MA_SUCCESS){
            LOG_ERROR("can't stop sound device");
        }*/
    }
    float Volume() const { return m_volume.load(std::memory_order_relaxed); }
    bool  Muted() const { return m_muted.load(std::memory_order_relaxed); }
    void  SetMuted(bool v) { m_muted.store(v, std::memory_order_relaxed); }

    void SetVolume(float v) {
        m_volume.store(wallpaper::audio::ClampVolume(v), std::memory_order_relaxed);
    }
    void MountChannel(std::shared_ptr<Channel> chn) {
        ChannelWrap chnw;
        chnw.chn = chn;
        chnw.chn->PassDeviceDesc(GetDesc());
        {
            std::unique_lock<std::mutex> lock { m_mutex };
            m_channels.push_back(chnw);
        }
    }
    void UnmountAll() {
        {
            std::unique_lock<std::mutex> lock { m_mutex };
            m_channels.clear();
        }
    }
    DeviceDesc GetDesc() const {
        return DeviceDesc { .phyChannels = m_device.playback.channels,
                            .sampleRate  = m_device.sampleRate };
    }

private:
    static void data_callback(ma_device* pMaDevice, void* pOutput, const void* pInput,
                              ma_uint32 frameCount) {
        Device* pDevice = static_cast<Device*>(pMaDevice->pUserData);
        if (! pDevice->IsInited()) return;
        pDevice->data_callback(pOutput, pInput, frameCount);
    }
    void data_callback(void* pOutput, const void* pInput, ma_uint32 frameCount) {
        (void)pInput;
        const auto phyChannels = m_device.playback.channels;
        if (phyChannels == 0) return;
        const auto framesSize     = frameCount * phyChannels;
        const auto framesByteSize = framesSize * sizeof(float);
        wallpaper::audio::ClearInterleavedF32(pOutput, framesSize);
        if (! m_running.load(std::memory_order_relaxed) ||
            m_muted.load(std::memory_order_relaxed)) {
            return;
        }
        {
            if (m_frameBuffer.size() < framesByteSize) m_frameBuffer.resize(framesByteSize);
        }
        {
            std::unique_lock<std::mutex> lock { m_mutex, std::try_to_lock };
            if (! lock.owns_lock()) return;

            float*      pOutput_float = static_cast<float*>(pOutput);
            float*      pBuffer_float = reinterpret_cast<float*>(m_frameBuffer.data());
            const float volume        = m_volume.load(std::memory_order_relaxed);
            for (ma_uint32 i = 0; i < m_channels.size(); i++) {
                wallpaper::audio::ClearInterleavedF32(m_frameBuffer.data(), framesSize);
                ma_uint64 framesReaded =
                    m_channels[i].chn->NextPcmData(m_frameBuffer.data(), frameCount);
                if (framesReaded == 0) {
                    m_channels[i].end = true;
                } else {
                    const auto framesToMix = static_cast<std::size_t>(
                        std::min<ma_uint64>(framesReaded, frameCount) * phyChannels);
                    wallpaper::audio::MixInterleavedF32(
                        pOutput_float, pBuffer_float, framesToMix, volume);
                }
            }
            m_channels.erase(std::remove_if(m_channels.begin(),
                                            m_channels.end(),
                                            [](auto& c) {
                                                return c.end;
                                            }),
                             m_channels.end());
        }
    }
    ma_device_config GenMaDeviceConfig(const DeviceDesc& d) {
        ma_device_config config  = ma_device_config_init(ma_device_type_playback);
        config.sampleRate        = d.sampleRate;
        config.playback.format   = ma_format_f32;
        config.playback.channels = d.phyChannels;
        config.dataCallback      = data_callback;
        config.pUserData         = (void*)this;
        return config;
    }

private:
    struct ChannelWrap {
        bool                     end { false };
        std::shared_ptr<Channel> chn;
    };
    ma_device         m_device {}; // must init c struct
    std::mutex        m_mutex;     // for operating channel vector
    std::atomic<bool> m_running { false };

    std::atomic<float> m_volume { 1.0f };
    std::atomic<bool>  m_muted { false };

    std::vector<ChannelWrap> m_channels;
    std::vector<uint8_t>     m_frameBuffer;
};

} // namespace miniaudio
