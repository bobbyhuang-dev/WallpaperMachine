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
    const auto start = std::chrono::steady_clock::time_point(1s);
    timer.FrameBegin(start);
    timer.FrameEnd(start + 8h);

    EXPECT_EQ(timer.m_frame_busy_count.load(), 0);
    EXPECT_LT(timer.FrameTime(), 0.1);
    EXPECT_NEAR(timer.IdeaTime(), 0.05, 0.01);

    timer.FrameBegin(start + 8h + 50ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.05);
}

TEST(FrameTimerTest, DeliveredFramesIncludeDroppedTickIntervals) {
    int draws = 0;
    FrameTimer timer([&]() { ++draws; });
    timer.SetRequiredFps(30);
    const auto start = std::chrono::steady_clock::time_point(1s);

    // A 40 ms draw misses every other tick of a 33.333 ms scheduler.
    // Drive those ticks and delivered-frame timestamps without wall-clock sleeps.
    for (int frame = 0; frame < 6; ++frame) {
        const auto begin = start + frame * 66666us;
        timer.m_timer.m_callback();
        ASSERT_EQ(draws, frame + 1);
        timer.FrameBegin(begin);
        EXPECT_DOUBLE_EQ(timer.IdeaTime(), frame == 0 ? 0.033333 : 0.066666);

        timer.m_timer.m_callback();
        EXPECT_EQ(draws, frame + 1);
        timer.FrameEnd(begin + 40ms);
    }

    // Rendering cost remains distinct from animation time.
    EXPECT_DOUBLE_EQ(timer.FrameTime(), 0.04);
}

TEST(FrameTimerTest, RestartExcludesPausedTimeButRunningAgainPreservesElapsedTime) {
    FrameTimer timer;
    timer.SetRequiredFps(20);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.Run();
    timer.FrameBegin(start);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.05);
    timer.FrameEnd(start + 10ms);

    timer.Run();
    timer.FrameBegin(start + 100ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.1);
    timer.FrameEnd(start + 110ms);
    timer.Stop();

    // Use a pause shorter than the long-frame cutoff so only Run's reset can
    // exclude it. The following frame must use elapsed time normally again.
    timer.Run();
    timer.FrameBegin(start + 2s);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.05);
    timer.FrameEnd(start + 2010ms);
    timer.FrameBegin(start + 2100ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.1);
    timer.FrameEnd(start + 2110ms);
    timer.Stop();
}

TEST(FrameTimerTest, FpsChangePreservesInFlightDrawAndElapsedTime) {
    int draws = 0;
    FrameTimer timer([&]() { ++draws; });
    timer.SetRequiredFps(20);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.m_timer.m_callback();
    timer.FrameBegin(start);
    timer.SetRequiredFps(40);
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 1);
    timer.FrameEnd(start + 60ms);

    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 2);
    timer.FrameBegin(start + 75ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.075);
    timer.FrameEnd(start + 85ms);
}

TEST(FrameTimerTest, LongDeliveryGapDoesNotCatchUpSuspendedTime) {
    FrameTimer timer;
    timer.SetRequiredFps(20);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);
    timer.FrameBegin(start + 8h);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.05);
    timer.FrameEnd(start + 8h + 10ms);
    timer.FrameBegin(start + 8h + 100ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.1);
    timer.FrameEnd(start + 8h + 110ms);
}

TEST(FrameTimerTest, ContentThatChangesLessOftenLowersTheTickRate) {
    FrameTimer timer;
    timer.SetRequiredFps(60);
    EXPECT_EQ(timer.TickInterval(), 16666us) << "no demand keeps the configured cadence";

    // A 30 fps video behind a 60 fps ceiling: rendering 60 times a second would
    // present every decoded frame twice.
    timer.SetFrameDemand({ .content_period = 33333us });
    EXPECT_EQ(timer.TickInterval(), 33333us);

    // Raising the ceiling does not raise the content's rate.
    timer.SetRequiredFps(120);
    EXPECT_EQ(timer.TickInterval(), 33333us);
}

TEST(FrameTimerTest, TheConfiguredFpsStaysTheCeiling) {
    FrameTimer timer;
    timer.SetRequiredFps(30);

    // A 60 fps video must not make a 30 fps wallpaper render at 60: the user's
    // and the display's limit wins.
    timer.SetFrameDemand({ .content_period = 16666us });
    EXPECT_EQ(timer.TickInterval(), 33333us);

    // A period equal to the ideal frame time changes nothing either.
    timer.SetFrameDemand({ .content_period = 33333us });
    EXPECT_EQ(timer.TickInterval(), 33333us);
}

TEST(FrameTimerTest, AnUnknownOrAbsurdPeriodCannotStallTheScene) {
    FrameTimer timer;
    timer.SetRequiredFps(30);

    // Zero is how a source says it does not know its own rate.
    timer.SetFrameDemand({ .content_period = 0us });
    EXPECT_EQ(timer.TickInterval(), 33333us);
    timer.SetFrameDemand({ .content_period = -5s });
    EXPECT_EQ(timer.TickInterval(), 33333us) << "a negative period is not a licence to stop";

    // A wildly long period is clamped to the longest gap the frame clock still
    // treats as continuous playback, so the scene keeps a heartbeat.
    timer.SetFrameDemand({ .content_period = 1h });
    EXPECT_EQ(timer.TickInterval(), 5s);
}

TEST(FrameTimerTest, DroppingTheDemandRestoresTheFixedCadence) {
    FrameTimer timer;
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({ .content_period = 500ms });
    EXPECT_EQ(timer.TickInterval(), 500ms);

    // Switching to a scene that cannot prove its rate must go back to ticking
    // at the configured rate rather than inheriting the previous scene's.
    timer.SetFrameDemand({});
    EXPECT_EQ(timer.TickInterval(), 16666us);
}

TEST(FrameTimerTest, ContentPacingKeepsTheSingleDrawInFlightLimit) {
    int  draws { 0 };
    FrameTimer timer([&draws]() {
        draws++;
    });
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({ .content_period = 100ms });
    const auto start = std::chrono::steady_clock::time_point(1s);

    // Pacing changes when a draw is posted, never how many may be outstanding.
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 1);
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 1) << "a frame still in flight must not be joined by another";

    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 2);
    EXPECT_EQ(timer.TickInterval(), 100ms);
}

} // namespace
} // namespace wallpaper
