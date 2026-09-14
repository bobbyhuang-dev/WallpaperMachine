#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>

#define private public
#include "Timer/FrameTimer.hpp"
#undef private

#include <gtest/gtest.h>

namespace wallpaper
{
namespace
{

using namespace std::chrono_literals;

TEST(FrameTimerTest, RunClearsStaleSchedulerStateBeforeStarting) {
    FrameTimer timer;
    timer.SetRequiredFps(20);

    timer.m_frame_busy_count.store(7);
    timer.AddFrametime(std::chrono::hours(8));
    timer.UpdateFrametime();
    timer.m_timer.SetInterval(std::chrono::hours(24));

    ASSERT_GT(timer.FrameTime(), 60.0);

    timer.Run();
    timer.Stop();

    EXPECT_EQ(timer.m_frame_busy_count.load(), 0);
    EXPECT_LT(timer.FrameTime(), 0.1);
    EXPECT_NEAR(timer.IdeaTime(), 0.05, 0.01);
}

TEST(FrameTimerTest, FrameEndDropsSuspendedFrameDuration) {
    FrameTimer timer;
    timer.SetRequiredFps(20);

    timer.m_frame_busy_count.store(1);
    timer.m_clock = std::chrono::steady_clock::now() - std::chrono::hours(8);

    timer.FrameEnd();

    EXPECT_EQ(timer.m_frame_busy_count.load(), 0);
    EXPECT_LT(timer.FrameTime(), 0.1);
    EXPECT_NEAR(timer.IdeaTime(), 0.05, 0.01);
}

} // namespace
} // namespace wallpaper
