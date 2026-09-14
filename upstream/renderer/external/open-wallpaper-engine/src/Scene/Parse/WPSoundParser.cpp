#include "WPSoundParser.hpp"

#include "Audio/SampleMath.h"
#include "Fs/VFS.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Utils/Logging.h"
#include "wpscene/WPSoundObject.h"

#include <algorithm>
#include <random>
#include <string>
#include <string_view>
#include <utility>

using namespace wallpaper;

PlaybackMode wallpaper::ParseSoundPlaybackMode(std::string_view value) {
    if (value == "single") return PlaybackMode::OneShot;
    if (value == "random") return PlaybackMode::Random;
    return PlaybackMode::Loop;
}

WPSoundStream::WPSoundStream(const std::vector<std::string>& paths, fs::VFS& vfs, Config config)
    : WPSoundStream(
          [&paths, &vfs] {
              std::vector<StreamFactory> factories;
              factories.reserve(paths.size());
              for (const auto& path : paths) {
                  factories.emplace_back([&vfs, path](const Desc& desc) {
                      return std::shared_ptr<audio::SoundStream>(
                          audio::CreateSoundStream(vfs.Open("/assets/" + path),
                                                   desc,
                                                   { .loop = false }));
                  });
              }
              return factories;
          }(),
          config) {}

WPSoundStream::WPSoundStream(std::vector<StreamFactory> factories, Config config)
    : m_config(config),
      m_stream_factories(std::move(factories)),
      m_volume(audio::ClampVolume(config.volume)),
      m_muted(config.muted),
      m_playing(! config.startsilent) {
    m_config.volume = m_volume.load(std::memory_order_relaxed);
}

WPSoundStream::~WPSoundStream() = default;

uint64_t WPSoundStream::NextPcmData(void* data, uint32_t frame_count) {
    if (m_desc.channels == 0 || m_stream_factories.empty()) return 0;

    const auto sample_count = static_cast<std::size_t>(frame_count) * m_desc.channels;
    audio::ClearInterleavedF32(data, sample_count);

    if (m_rewind_requested.exchange(false, std::memory_order_relaxed)) {
        m_cur_active.reset();
        m_cur_index = 0;
        m_finished.store(false, std::memory_order_relaxed);
    }

    if (! m_cur_active) {
        Switch();
    }
    if (! m_cur_active) return 0;

    if (! m_playing.load(std::memory_order_relaxed)) {
        return frame_count;
    }

    uint64_t frames_read = m_cur_active->NextPcmData(data, frame_count);
    if (frames_read == 0) {
        if (m_config.mode == PlaybackMode::OneShot) {
            m_playing.store(false, std::memory_order_relaxed);
            m_finished.store(true, std::memory_order_relaxed);
            return frame_count;
        }
        Switch();
        if (! m_cur_active) return frame_count;
        frames_read = m_cur_active->NextPcmData(data, frame_count);
        if (frames_read == 0) return frame_count;
    }

    const auto samples_read =
        static_cast<std::size_t>(std::min<uint64_t>(frames_read, frame_count) * m_desc.channels);
    if (m_muted.load(std::memory_order_relaxed)) {
        audio::ClearInterleavedF32(data, samples_read);
    } else {
        audio::ApplyVolumeF32(data, samples_read, m_volume.load(std::memory_order_relaxed));
    }
    return frames_read;
}

void WPSoundStream::PassDesc(const Desc& desc) {
    m_desc = desc;
    if (m_cur_active != nullptr) m_cur_active->PassDesc(desc);
}

void WPSoundStream::Play() {
    if (m_finished.exchange(false, std::memory_order_relaxed)) {
        m_rewind_requested.store(true, std::memory_order_relaxed);
    }
    m_playing.store(true, std::memory_order_relaxed);
}

void WPSoundStream::Pause() { m_playing.store(false, std::memory_order_relaxed); }

void WPSoundStream::Stop() {
    m_playing.store(false, std::memory_order_relaxed);
    m_finished.store(false, std::memory_order_relaxed);
    m_rewind_requested.store(true, std::memory_order_relaxed);
}

bool WPSoundStream::IsPlaying() const { return m_playing.load(std::memory_order_relaxed); }

void WPSoundStream::SetVolume(float volume) {
    m_volume.store(audio::ClampVolume(volume), std::memory_order_relaxed);
}

float WPSoundStream::Volume() const { return m_volume.load(std::memory_order_relaxed); }

void WPSoundStream::SetMuted(bool muted) { m_muted.store(muted, std::memory_order_relaxed); }

bool WPSoundStream::Muted() const { return m_muted.load(std::memory_order_relaxed); }

void WPSoundStream::Switch() {
    if (m_stream_factories.empty()) return;
    auto stream = m_stream_factories[LoopIndex()](m_desc);
    if (stream == nullptr) {
        m_cur_active.reset();
        return;
    }
    stream->PassDesc(m_desc);
    m_cur_active = std::move(stream);
}

std::size_t WPSoundStream::LoopIndex() {
    if (m_config.mode == PlaybackMode::Random) {
        std::uniform_int_distribution<std::size_t> distribution(0, m_stream_factories.size() - 1);
        return distribution(m_random);
    }

    const std::size_t index = m_cur_index;
    m_cur_index++;
    if (m_cur_index == m_stream_factories.size()) m_cur_index = 0;
    return index;
}

void WPSoundParser::Parse(const wpscene::WPSoundObject& obj, fs::VFS& vfs, audio::SoundManager& sm,
                          SceneRuntimeContext* runtime) {
    WPSoundStream::Config config { .maxtime     = obj.maxtime,
                                   .mintime     = obj.mintime,
                                   .volume      = audio::ClampVolume(obj.volume),
                                   .muted       = obj.muted,
                                   .startsilent = obj.startsilent,
                                   .mode        = ParseSoundPlaybackMode(obj.playbackmode) };

    auto stream = std::make_shared<WPSoundStream>(obj.sound, vfs, config);
    if (runtime != nullptr) {
        runtime->RegisterSoundLayer(obj.name, stream);
    }
    sm.MountStream(stream);
}
