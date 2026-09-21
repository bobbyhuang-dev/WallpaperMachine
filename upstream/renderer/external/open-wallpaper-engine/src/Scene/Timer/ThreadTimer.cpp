#include "ThreadTimer.hpp"

#include "Utils/Logging.h"

#include <algorithm>
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

void ThreadTimer::SetMinInterval(micros v) {
    m_min_interval = v;
    // A ceiling that just got looser has to shorten a wait taken under the old
    // one; a tighter ceiling is picked up on the next re-check either way.
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
                    // The user's FPS ceiling is a floor on the gap between two
                    // callbacks, and it binds every path into one — not only
                    // the cadence. The cadence alone cannot carry it: content
                    // pacing makes `m_interval` *longer* than the ceiling, so
                    // an interval of 1s says nothing about how close together
                    // two event-driven frames may run.
                    //
                    // Before this, a one-shot request was honoured immediately
                    // whenever the clock was idle, so anything that asks for a
                    // frame — pointer movement, at the pointer sample rate —
                    // drove the scene at the rate the events arrived at rather
                    // than at the rate the user configured.
                    const auto earliest = last_tick + m_min_interval.load();

                    if (m_idle) {
                        // An idle clock has no cadence, so the only deadlines
                        // are the ones something asked for. A request is due at
                        // the ceiling: after a long sleep that moment is
                        // already past and the frame runs at once, and during a
                        // burst the requests coalesce into one frame per
                        // period instead of one frame each.
                        std::optional<std::chrono::steady_clock::time_point> due;
                        if (m_wake_once) {
                            due = earliest;
                        } else if (m_wake_at.has_value()) {
                            // An appointment already past is owed, not urgent:
                            // clamping it to the ceiling is what stops a
                            // deadline that keeps being re-armed in the past
                            // from spinning the thread.
                            due = std::max(*m_wake_at, earliest);
                        }
                        if (! due.has_value()) {
                            // No deadline at all. This is the difference
                            // between an idle scene and a slow one: a slow
                            // scene still wakes to find nothing to do.
                            m_condition.wait(lock);
                            continue;
                        }
                        const auto now = std::chrono::steady_clock::now();
                        if (now >= *due) {
                            m_wake_once = false;
                            // Only a kept appointment is consumed. One that is
                            // still in the future survives a frame that ran for
                            // another reason, so a layer that asked to redraw
                            // on the minute still redraws on the minute.
                            if (m_wake_at.has_value() && now >= *m_wake_at) m_wake_at.reset();
                            break;
                        }
                        m_condition.wait_until(lock, *due);
                        continue;
                    }

                    auto deadline = last_tick + m_interval.load();
                    // A pending request may cut a long content-paced wait
                    // short, because the event is new content the period did
                    // not predict — but only as far as the ceiling, never past
                    // it. When the cadence is the ceiling this changes nothing.
                    if (m_wake_once && earliest < deadline) deadline = earliest;
                    if (std::chrono::steady_clock::now() >= deadline) {
                        // The tick satisfies any pending request: the frame it
                        // is about to run is the frame that was asked for.
                        // Clearing here rather than discarding at the request
                        // site is what keeps the latch meaningful — a request
                        // is never dropped, only absorbed by a real frame.
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
