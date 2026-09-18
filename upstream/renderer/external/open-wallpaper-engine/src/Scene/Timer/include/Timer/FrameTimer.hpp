#pragma once

#include "Core/RendererCounters.hpp"
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

    /// How often the content itself can change.
    ///
    /// The required FPS is a ceiling chosen by the user and the display; it says
    /// nothing about how often the scene has something new to show. A source
    /// that reports a longer period than the ideal frame time lowers the tick
    /// rate to its own rate, which removes renders that would present identical
    /// pixels. It can never raise the rate above the ceiling, and an absent or
    /// zero period keeps the fixed cadence, so a scene that cannot prove its own
    /// rate is unaffected.
    struct FrameDemand {
        /// Zero when the content cannot say how often it changes.
        std::chrono::microseconds content_period { std::chrono::microseconds::zero() };
    };

    /// Pushed by the owner from the render thread, so the timer thread never
    /// reaches into scene or renderer state to ask.
    void SetFrameDemand(FrameDemand);

    /// Interval the next tick will use, for diagnostics and tests.
    [[nodiscard]] std::chrono::microseconds TickInterval() const;

    /// Gap above which a frame boundary is read as the process having been
    /// suspended rather than as the content simply not having changed yet.
    ///
    /// A fixed threshold silently collides with content pacing: a scene paced
    /// at the clamp would have every ordinary tick misread as a resume, its
    /// elapsed time replaced by one ideal frame, and its playback would fall
    /// behind by the difference every frame. The threshold therefore scales
    /// with the interval the clock is actually using, and never drops below the
    /// fixed floor.
    [[nodiscard]] std::chrono::microseconds SuspensionThreshold() const;

    /// Counters are owned by the scene and outlive the timer. Install before
    /// `Run`; the timer thread only reads the pointer.
    void SetCounters(RendererCounters* counters);

    // only used with one render
    void FrameBegin();
    void FrameEnd();

private:
    void ResetFrameTiming();
    void AddFrametime(std::chrono::microseconds);
    void UpdateFrametime();
    void FrameBegin(std::chrono::steady_clock::time_point now);
    void FrameEnd(std::chrono::steady_clock::time_point now);
    std::chrono::microseconds ResolveInterval();

    std::function<void()>                 m_callback;
    std::deque<std::chrono::microseconds> m_frametime_queue;
    std::atomic<RendererCounters*>        m_counters { nullptr };

    std::atomic<u16>                        m_req_fps;
    std::atomic<std::chrono::microseconds> m_frametime;
    std::atomic<std::chrono::microseconds> m_ideatime;
    std::atomic<std::chrono::microseconds> m_elapsed_frametime;
    std::atomic<std::chrono::microseconds> m_tick_interval;
    /// Zero means unknown, which keeps the fixed cadence.
    std::atomic<std::chrono::microseconds> m_content_period { std::chrono::microseconds::zero() };
    std::atomic<bool>                      m_reset_frame_clock { true };
    std::atomic<i32>                       m_frame_busy_count;

    ThreadTimer m_timer;

    // out of time thread
    std::chrono::time_point<std::chrono::steady_clock> m_clock;
};
} // namespace wallpaper
