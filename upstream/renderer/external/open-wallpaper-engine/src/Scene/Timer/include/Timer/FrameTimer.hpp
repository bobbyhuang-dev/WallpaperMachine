#pragma once

#include "ThreadTimer.hpp"
#include <deque>

namespace wallpaper
{
class FrameTimer : NoCopy, NoMove {
    constexpr static usize FRAMETIME_QUEUE_SIZE { 5 };

public:
    FrameTimer(std::function<void()> callback = {});
    ~FrameTimer();

    // call brefore run
    void SetCallback(const std::function<void()>&);

    void Run();
    void Stop();

    u16    RequiredFps() const;
    bool   Running() const;
    // Smoothed render work duration, excluding time between delivered frames.
    double FrameTime() const;
    // Elapsed delivered-frame time, excluding stopped time.
    double IdeaTime() const;

    void SetRequiredFps(u16);

    // only used with one render
    void FrameBegin();
    void FrameEnd();

private:
    void ResetFrameTiming();
    void AddFrametime(std::chrono::microseconds);
    void UpdateFrametime();
    void FrameBegin(std::chrono::steady_clock::time_point now);
    void FrameEnd(std::chrono::steady_clock::time_point now);

    std::function<void()>                 m_callback;
    std::deque<std::chrono::microseconds> m_frametime_queue;

    std::atomic<u16>                        m_req_fps;
    std::atomic<std::chrono::microseconds> m_frametime;
    std::atomic<std::chrono::microseconds> m_ideatime;
    std::atomic<std::chrono::microseconds> m_elapsed_frametime;
    std::atomic<bool>                      m_reset_frame_clock { true };
    std::atomic<i32>                       m_frame_busy_count;

    ThreadTimer m_timer;

    // out of time thread
    std::chrono::time_point<std::chrono::steady_clock> m_clock;
};
} // namespace wallpaper
