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

    /// Runs the callback once as soon as the thread can, whether idle or
    /// waiting on a deadline, and without disturbing the cadence.
    ///
    /// The request is a latch, not a notification: it is recorded under the
    /// same mutex the waiter re-checks, so a wake that lands between the
    /// decision to idle and the wait itself still produces a tick instead of
    /// being lost.
    void WakeOnce();

    /// Schedules exactly one tick at `when` while idle, replacing any deadline
    /// already scheduled.
    ///
    /// This is for content that knows when it next changes — a clock layer
    /// that redraws on the minute — and it is a single appointment, not a
    /// cadence: after the tick the thread is idle again unless the frame that
    /// ran asks for another. `when` in the past ticks immediately.
    void WakeAt(std::chrono::steady_clock::time_point when);

private:
    std::function<void()> m_callback;

    std::mutex m_op_mutex;

    std::thread             m_timer_thread;
    mutable std::mutex      m_cond_mutex;
    std::condition_variable m_condition;

    // init
    std::atomic<std::chrono::microseconds> m_interval;
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
