#include "FrameTimer.hpp"
#include "Utils//Logging.h"

#include <numeric>

using namespace wallpaper;
using micros = std::chrono::microseconds;
using namespace std::chrono;

namespace
{
constexpr auto MAX_FRAME_DURATION = seconds(5);
constexpr u16  DEFAULT_REQUIRED_FPS { 30 };
}

FrameTimer::FrameTimer(std::function<void()> cb)
    : m_callback(cb), m_frame_busy_count(0), m_timer([this]() {
          // Fixed-rate clock. The callback only posts CMD_DRAW to the render
          // looper, so the tick period must be the ideal frame time; halving it
          // when a frame runs long makes a slow scene render flat out instead of
          // degrading to its achievable rate.
          m_timer.SetInterval(m_ideatime.load());

          // At most one DRAW may be in flight. A slow frame drops ticks rather
          // than queueing work the display will never show.
          if (m_callback && m_frame_busy_count.load() < 1) {
              m_frame_busy_count++;
              m_callback();
          }
      }) {
    SetRequiredFps(DEFAULT_REQUIRED_FPS);
    ResetFrameTiming();
}

FrameTimer::~FrameTimer() {};

u16 FrameTimer::RequiredFps() const { return m_req_fps; }

double FrameTimer::FrameTime() const {
    return duration_cast<duration<double>>(m_frametime.load()).count();
}

double FrameTimer::IdeaTime() const {
    return duration_cast<duration<double>>(m_elapsed_frametime.load()).count();
}

void FrameTimer::UpdateFrametime() {
    m_frametime.store(std::accumulate(m_frametime_queue.begin(),
                                      m_frametime_queue.end(),
                                      duration_cast<microseconds>(0s)) /
                      m_frametime_queue.size());
}

void FrameTimer::ResetFrameTiming() {
    m_frametime_queue.clear();
    for (usize i = 0; i < FrameTimer::FRAMETIME_QUEUE_SIZE; i++) {
        AddFrametime(m_ideatime.load());
    }
    UpdateFrametime();
    m_elapsed_frametime.store(m_ideatime.load());
    m_reset_frame_clock.store(true);
}

void FrameTimer::SetRequiredFps(u16 value) {
    m_req_fps  = value > 0 ? value : DEFAULT_REQUIRED_FPS;
    m_ideatime = microseconds(1'000'000 / m_req_fps.load());
    // An FPS change must not discard an in-flight draw or its elapsed time.
    m_timer.SetInterval(m_ideatime.load());
}

void FrameTimer::AddFrametime(micros t) {
    m_frametime_queue.push_back(t);
    while (m_frametime_queue.size() > FrameTimer::FRAMETIME_QUEUE_SIZE) {
        m_frametime_queue.pop_front();
    }
}

void FrameTimer::FrameBegin() { FrameBegin(steady_clock::now()); }
void FrameTimer::FrameBegin(steady_clock::time_point now) {
    const auto elapsed = duration_cast<microseconds>(now - m_clock);
    // The first frame after Run has no active predecessor. Treat very long
    // gaps as suspension too, rather than feeding hours into scene simulation.
    const bool reset = m_reset_frame_clock.exchange(false);
    m_elapsed_frametime.store(reset || elapsed > MAX_FRAME_DURATION
                                 ? m_ideatime.load()
                                 : elapsed);
    m_clock = now;
}
void FrameTimer::FrameEnd() { FrameEnd(steady_clock::now()); }
void FrameTimer::FrameEnd(steady_clock::time_point now) {
    auto elapsed = duration_cast<microseconds>(now - m_clock);
    if (elapsed > MAX_FRAME_DURATION) {
        ResetFrameTiming();
    } else {
        AddFrametime(elapsed);
        UpdateFrametime();
    }

    i32 expected = m_frame_busy_count.load();
    while (expected > 0) {
        if (m_frame_busy_count.compare_exchange_weak(expected, expected - 1)) {
            break;
        }
    }
}

void FrameTimer::SetCallback(const std::function<void()>& cb) {
    if (! Running()) m_callback = cb;
}
void FrameTimer::Run() {
    if (! Running()) {
        ResetFrameTiming();
        m_frame_busy_count.store(0);
        m_timer.SetInterval(m_ideatime.load());
    }
    m_timer.Start();
}
void FrameTimer::Stop() { m_timer.Stop(); }
bool FrameTimer::Running() const { return m_timer.Running(); }
