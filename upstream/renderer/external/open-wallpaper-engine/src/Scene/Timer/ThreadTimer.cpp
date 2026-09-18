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
                    const auto deadline = last_tick + m_interval.load();
                    if (std::chrono::steady_clock::now() >= deadline) break;
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
