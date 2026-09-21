#pragma once

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"

#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>

#include <functional>
#include <chrono>
#include <optional>

namespace wallpaper
{

class ThreadTimer : NoCopy, NoMove {
public:
    ThreadTimer(std::function<void()> callback);
    ~ThreadTimer();

    void Start();
    void Stop();

    bool Running() const;

    void SetInterval(std::chrono::microseconds);

    /// Shortest gap allowed between two callbacks, whatever asked for them.
    ///
    /// `SetInterval` is the cadence, and content pacing is free to make it
    /// *longer* than the user's frame ceiling. That leaves the ceiling itself
    /// unrepresented, so every non-cadence path into the callback — a one-shot
    /// request, an appointment, an appointment already past — had nothing to
    /// clamp it and could drive the scene as fast as events arrived. This is
    /// that ceiling, expressed where every path has to pass it: the earliest
    /// moment a callback may run is always `last callback + min interval`.
    ///
    /// Zero disables the floor, which is the behaviour of a timer whose owner
    /// never states a ceiling.
    void SetMinInterval(std::chrono::microseconds);

    /// Suspends the periodic deadline entirely.
    ///
    /// While idle the thread waits on its condition variable with no timeout,
    /// so the scene costs no wakeups at all. This is deliberately not "a very
    /// long interval": a long interval still wakes, and a wallpaper that has
    /// nothing to draw should not wake to decide that again. Leaving idle
    /// restarts the cadence from the moment of the call rather than from the
    /// stale deadline the thread was holding.
    void SetIdle(bool idle);

    [[nodiscard]] bool Idle() const;

    /// Runs the callback once at the earliest moment the frame ceiling allows,
    /// whether idle or waiting on a deadline, and without disturbing the
    /// cadence.
    ///
    /// The request is a latch, not a notification: it is recorded under the
    /// same mutex the waiter re-checks, so a wake that lands between the
    /// decision to idle and the wait itself still produces a tick instead of
    /// being lost. The latch also survives a wait: a burst of requests
    /// coalesces into one tick at the ceiling rather than one tick each.
    void WakeOnce();

    /// Schedules exactly one tick at `when` while idle, replacing any deadline
    /// already scheduled.
    ///
    /// This is for content that knows when it next changes — a clock layer
    /// that redraws on the minute — and it is a single appointment, not a
    /// cadence: after the tick the thread is idle again unless the frame that
    /// ran asks for another. `when` in the past ticks at the next moment the
    /// frame ceiling allows, which is immediately after a long idle and one
    /// full frame period after a tick — an owed frame is not a licence to spin.
    void WakeAt(std::chrono::steady_clock::time_point when);

private:
    std::function<void()> m_callback;

    std::mutex m_op_mutex;

    std::thread             m_timer_thread;
    mutable std::mutex      m_cond_mutex;
    std::condition_variable m_condition;

    // init
    std::atomic<std::chrono::microseconds> m_interval;
    /// Ceiling on callback frequency; zero means no floor on the gap.
    std::atomic<std::chrono::microseconds> m_min_interval { std::chrono::microseconds::zero() };
    std::atomic<bool>                      m_running;
    /// Guarded by `m_cond_mutex` together with the wait, so the waiter cannot
    /// miss a request made while it was between checks.
    bool                                   m_idle { false };
    bool                                   m_wake_once { false };
    /// Set when leaving idle so the thread restarts its cadence from now.
    bool                                   m_rebase { false };
    /// One-shot appointment honoured while idle; unset means no deadline.
    std::optional<std::chrono::steady_clock::time_point> m_wake_at;
};

} // namespace wallpaper
