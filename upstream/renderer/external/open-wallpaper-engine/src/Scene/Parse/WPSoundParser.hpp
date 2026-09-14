#pragma once

#include "Audio/SoundManager.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <random>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{

namespace fs
{
class VFS;
}
namespace wpscene
{
class WPSoundObject;
}

class SceneRuntimeContext;

enum class PlaybackMode
{
    OneShot,
    Random,
    Loop
};

[[nodiscard]] PlaybackMode ParseSoundPlaybackMode(std::string_view value);

class WPSoundStream : public audio::SoundStream {
public:
    using StreamFactory =
        std::function<std::shared_ptr<audio::SoundStream>(const audio::SoundStream::Desc&)>;

    struct Config {
        float        maxtime { 10.0f };
        float        mintime { 0.0f };
        float        volume { 1.0f };
        bool         muted { false };
        bool         startsilent { false };
        PlaybackMode mode { PlaybackMode::OneShot };
    };

    WPSoundStream(const std::vector<std::string>& paths, fs::VFS& vfs, Config config);
    WPSoundStream(std::vector<StreamFactory> factories, Config config);
    ~WPSoundStream() override;

    uint64_t NextPcmData(void* data, uint32_t frame_count) override;
    void     PassDesc(const Desc& desc) override;

    void Play();
    void Pause();
    void Stop();
    bool IsPlaying() const;

    void  SetVolume(float volume);
    float Volume() const;
    void  SetMuted(bool muted);
    bool  Muted() const;

private:
    void        Switch();
    std::size_t LoopIndex();

    Config                              m_config;
    Desc                                m_desc {};
    std::size_t                         m_cur_index { 0 };
    std::vector<StreamFactory>          m_stream_factories;
    std::shared_ptr<audio::SoundStream> m_cur_active;
    std::mt19937                        m_random { std::random_device {}() };
    std::atomic<float>                  m_volume { 1.0f };
    std::atomic<bool>                   m_muted { false };
    std::atomic<bool>                   m_playing { true };
    std::atomic<bool>                   m_rewind_requested { false };
    std::atomic<bool>                   m_finished { false };
};

class WPSoundParser {
public:
    static void Parse(const wpscene::WPSoundObject&, fs::VFS&, audio::SoundManager&,
                      SceneRuntimeContext* runtime = nullptr);
};

} // namespace wallpaper
