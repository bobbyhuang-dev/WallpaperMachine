#include "ThreadTimer.hpp"

#include "Utils/Logging.h"

#include <cassert>

using namespace wallpaper;
using micros = std::chrono::microseconds;

ThreadTimer::ThreadTimer(std::function<void()> cb)
    : m_callback(std::move(cb)),
      m_interval(micros(0)),
      m_running(false) {}
ThreadTimer::~ThreadTimer() { Stop(); }

bool ThreadTimer::Running() const { return m_running; }

void ThreadTimer::SetInterval(micros v) {
    m_interval = v;
    // The wait already in progress has to see this. A clock paced to slow
    // content sits in a long wait by design; if a tighter content rate or a
    // higher target FPS could not cut that wait short, every frame produced
    // during the remainder of it is superseded before it is ever displayed.
    std::unique_lock<std::mutex> lock(m_cond_mutex);
    m_condition.notify_all();
}

void ThreadTimer::SetIdle(bool idle) {
    std::unique_lock<std::mutex> lock(m_cond_mutex);
    if (m_idle == idle) return;
    m_idle = idle;
    // Leaving idle has to rebase the cadence, or the thread would compare now
    // against a deadline from before the scene went quiet and fire a burst of
    // ticks to "catch up" on time when nothing was being drawn. A pending
    // appointment is dropped with it: the cadence supersedes it.
    if (! idle) {
        m_rebase = true;
        m_wake_at.reset();
    }
    // Without this the thread keeps whatever wait it is already in: entering
    // idle would not take effect until the pending deadline, and leaving idle
    // would never take effect at all, because an idle wait has no deadline.
    m_condition.notify_all();
}

bool ThreadTimer::Idle() const {
    std::unique_lock<std::mutex> lock(m_cond_mutex);
    return m_idle;
}

void ThreadTimer::WakeOnce() {
    std::unique_lock<std::mutex> lock(m_cond_mutex);
    m_wake_once = true;
    m_condition.notify_all();
}

void ThreadTimer::WakeAt(std::chrono::steady_clock::time_point when) {
    std::unique_lock<std::mutex> lock(m_cond_mutex);
    m_wake_at = when;
    m_condition.notify_all();
}

void ThreadTimer::Start() {
    std::unique_lock<std::mutex> lock(m_op_mutex);

    if (Running()) return;
    m_running = true;
    m_timer_thread = std::thread([this]() {
        LOG_INFO("thread timer started");
        // The deadline is derived from the last tick and the *current*
        // interval, recomputed on every wake, so an interval that shrank moves
        // the deadline closer and one that grew moves it out. Waking early is
        // not a tick: the loop re-checks the deadline instead.
        auto last_tick = std::chrono::steady_clock::now();
        while (Running()) {
            {
                std::unique_lock<std::mutex> lock(m_cond_mutex);
                while (Running()) {
                    if (m_rebase) {
                        m_rebase = false;
                        last_tick = std::chrono::steady_clock::now();
                    }
                    // A one-shot request is honoured immediately only while the
                    // clock is idle. A running clock already has a tick coming,
                    // and letting a request jump the interval would let anything
                    // that asks for a frame — pointer movement, at the pointer
                    // sample rate — drive the scene past its configured FPS
                    // ceiling. That would be a regression on the default path,
                    // where on-demand updating is off and the ceiling is the
                    // only thing bounding the frame rate.
                    //
                    // The request is NOT discarded when the clock is running:
                    // it stays latched and is cleared by the next cadence tick.
                    // That keeps the race closed — a request landing between
                    // the decision to idle and the wait itself survives into
                    // the idle state and fires exactly one frame there.
                    if (m_wake_once && m_idle) {
                        m_wake_once = false;
                        break;
                    }
                    if (m_idle) {
                        if (m_wake_at.has_value()) {
                            const auto when = *m_wake_at;
                            if (std::chrono::steady_clock::now() >= when) {
                                // The appointment is kept exactly once. Leaving
                                // it set would turn a single redraw into a spin
                                // on an expired deadline.
                                m_wake_at.reset();
                                break;
                            }
                            m_condition.wait_until(lock, when);
                            continue;
                        }
                        // No deadline at all. This is the difference between
                        // an idle scene and a slow one: a slow scene still
                        // wakes to find nothing to do.
                        m_condition.wait(lock);
                        continue;
                    }
                    const auto deadline = last_tick + m_interval.load();
                    if (std::chrono::steady_clock::now() >= deadline) {
                        // The cadence tick satisfies any pending request: the
                        // frame it is about to run is the frame that was asked
                        // for. Clearing here rather than discarding at the
                        // request site is what keeps the latch meaningful while
                        // the clock is running.
                        m_wake_once = false;
                        break;
                    }
                    m_condition.wait_until(lock, deadline);
                }
            }
            if (!Running()) break;
            last_tick = std::chrono::steady_clock::now();
            if (m_callback) m_callback();
        }
        LOG_INFO("thread timer exited");
    });
}

void ThreadTimer::Stop() {
    std::unique_lock<std::mutex> lock(m_op_mutex);
    assert(std::this_thread::get_id() != m_timer_thread.get_id());

    if (! Running()) return;
    m_running = false;
    LOG_INFO("thread timer stopping");

    {
        std::unique_lock<std::mutex> lock(m_cond_mutex);
        m_condition.notify_all();
    }

    if (m_timer_thread.joinable()) {
        m_timer_thread.join();
    }
}
