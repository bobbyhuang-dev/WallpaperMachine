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

void ThreadTimer::SetInterval(micros v) { m_interval = v; }

void ThreadTimer::Start() {
    std::unique_lock<std::mutex> lock(m_op_mutex);

    if (Running()) return;
    m_running = true;
    m_timer_thread = std::thread([this]() {
        LOG_INFO("thread timer started");
        while (Running()) {
            {
                std::unique_lock<std::mutex> lock(m_cond_mutex);
                m_condition.wait_for(lock, m_interval.load(), [this]() {
                    return !Running();
                });
            }
            if (!Running()) break;
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
