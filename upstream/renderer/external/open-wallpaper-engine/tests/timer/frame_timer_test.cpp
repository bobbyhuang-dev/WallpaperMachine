#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

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

TEST(FrameTimerTest, AContentWaitAtTheClampIsNotMistakenForASuspension) {
    // The regression this pins: the pacing clamp and the suspension cutoff were
    // the same 5 s constant, so a scene paced at the clamp had every ordinary
    // frame boundary read as a resume. Its elapsed time was replaced by one
    // ideal frame, and a video driven by that clock fell further behind on
    // every frame instead of playing at its own rate.
    FrameTimer timer;
    timer.SetRequiredFps(30);
    timer.SetFrameDemand({ .content_period = 5s });
    ASSERT_EQ(timer.TickInterval(), 5s);

    const auto start = std::chrono::steady_clock::time_point(1s);
    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);

    // Exactly one interval later, and then one interval plus ordinary
    // scheduling delay later. Both are the content waiting, not a suspension.
    timer.FrameBegin(start + 5s);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 5.0);
    timer.FrameEnd(start + 5s + 10ms);

    timer.FrameBegin(start + 10s + 120ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 5.12);
    timer.FrameEnd(start + 10s + 130ms);

    // Several low-frequency updates in a row must keep reporting real time, or
    // the playback clock drifts a little further behind with each one.
    auto moment = start + 10s + 120ms;
    for (int i = 0; i < 4; ++i) {
        moment += 5s + 40ms;
        timer.FrameBegin(moment);
        EXPECT_DOUBLE_EQ(timer.IdeaTime(), 5.04) << "low-frequency update " << i;
        timer.FrameEnd(moment + 10ms);
    }
}

TEST(FrameTimerTest, ARealSuspensionIsStillDetectedAtAPacedInterval) {
    FrameTimer timer;
    timer.SetRequiredFps(30);
    timer.SetFrameDemand({ .content_period = 5s });
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);

    // Far beyond any plausible content wait at this interval: the scene must
    // not be handed eight hours of simulation to catch up on.
    timer.FrameBegin(start + 8h);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.033333);
}

TEST(FrameTimerTest, TheSuspensionThresholdFollowsTheIntervalAndNeverDropsBelowTheFloor) {
    FrameTimer timer;
    timer.SetRequiredFps(30);
    EXPECT_EQ(timer.SuspensionThreshold(), 5s) << "an unpaced clock keeps the fixed floor";

    timer.SetFrameDemand({ .content_period = 100ms });
    EXPECT_EQ(timer.SuspensionThreshold(), 5s) << "a short period must not shorten the floor";

    timer.SetFrameDemand({ .content_period = 4s });
    EXPECT_EQ(timer.SuspensionThreshold(), 12s);
}

TEST(FrameTimerTest, StoppingWithADrawPendingDoesNotReplayTheStoppedTime) {
    int        draws { 0 };
    FrameTimer timer([&draws]() { draws++; });
    timer.SetRequiredFps(30);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.Run();
    timer.m_timer.m_callback();
    ASSERT_EQ(draws, 1);
    timer.FrameBegin(start);
    // The draw is still in flight when the clock stops.
    timer.Stop();
    timer.FrameEnd(start + 5ms);

    timer.Run();
    timer.FrameBegin(start + 30s);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.033333);
    EXPECT_EQ(timer.m_frame_busy_count.load(), 0)
        << "restarting must not inherit a draw that will never complete";
    timer.Stop();
}

TEST(FrameTimerTest, CountersRecordWhatTheProductionSchedulerDid) {
    RendererCounters counters;
    RendererCounters::SetEnabled(true);

    int        draws { 0 };
    FrameTimer timer([&draws]() { draws++; });
    timer.SetCounters(&counters);
    timer.SetRequiredFps(30);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.m_timer.m_callback();
    timer.FrameBegin(start);
    // A second tick while the first draw is outstanding: a wakeup happened, no
    // work was requested, and the difference has to be readable.
    timer.m_timer.m_callback();
    timer.FrameEnd(start + 10ms);
    timer.m_timer.m_callback();

    EXPECT_EQ(counters.Get(OWE_RC_TIMER_WAKEUPS), 3u);
    EXPECT_EQ(counters.Get(OWE_RC_DRAW_REQUESTS), 2u);
    EXPECT_EQ(counters.Get(OWE_RC_DRAW_TICKS_SUPPRESSED), 1u);
    EXPECT_EQ(draws, 2);
    EXPECT_EQ(counters.Get(OWE_RC_TICK_INTERVAL_MICROS), 33333u);
    EXPECT_EQ(counters.Get(OWE_RC_CONTENT_PERIOD_MICROS), 0u);

    timer.SetFrameDemand({ .content_period = 100ms });
    EXPECT_EQ(counters.Get(OWE_RC_TICK_INTERVAL_MICROS), 100000u);
    EXPECT_EQ(counters.Get(OWE_RC_CONTENT_PERIOD_MICROS), 100000u);

    RendererCounters::SetEnabled(false);
}

TEST(FrameTimerTest, CountingIsOffUntilItIsTurnedOn) {
    RendererCounters counters;
    ASSERT_FALSE(RendererCounters::Enabled());

    FrameTimer timer([]() {});
    timer.SetCounters(&counters);
    timer.SetRequiredFps(30);
    timer.m_timer.m_callback();

    EXPECT_EQ(counters.Get(OWE_RC_TIMER_WAKEUPS), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_DRAW_REQUESTS), 0u);
}

TEST(FrameTimerTest, ContentPacingChangesHowOftenTheRealSchedulerPostsDraws) {
    // Not the arithmetic: the running thread timer, at the interval the
    // production clock resolved, delivering to the production callback.
    RendererCounters::SetEnabled(true);

    const auto run_for = [](std::chrono::microseconds period) {
        RendererCounters counters;
        std::atomic<int> draws { 0 };
        FrameTimer       timer([&draws]() { draws.fetch_add(1); });
        timer.SetCounters(&counters);
        timer.SetRequiredFps(240);
        if (period > 0us) timer.SetFrameDemand({ .content_period = period });
        timer.Run();
        // The callback only posts work; completing the frame is the owner's
        // job, so the busy flag is cleared the way the render thread does it.
        const auto deadline = std::chrono::steady_clock::now() + 300ms;
        while (std::chrono::steady_clock::now() < deadline) {
            timer.FrameBegin();
            timer.FrameEnd();
            std::this_thread::sleep_for(1ms);
        }
        timer.Stop();
        return counters.Get(OWE_RC_DRAW_REQUESTS);
    };

    const auto unpaced = run_for(0us);
    const auto paced   = run_for(50ms);

    EXPECT_GT(unpaced, paced * 2)
        << "a 50 ms content period must post far fewer draws than a 240 fps ceiling";
    EXPECT_GT(paced, 0u) << "pacing must not stop the scene";

    RendererCounters::SetEnabled(false);
}

/// Waits until `predicate` holds or the budget runs out, and reports how long
/// that took. No busy spin: the callback signals.
template<typename Predicate>
std::chrono::milliseconds WaitFor(std::mutex&              mutex,
                                  std::condition_variable& condition,
                                  Predicate                predicate,
                                  std::chrono::milliseconds budget) {
    const auto start = std::chrono::steady_clock::now();
    std::unique_lock<std::mutex> lock(mutex);
    condition.wait_for(lock, budget, predicate);
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
}

TEST(FrameTimerTest, AShortenedIntervalDoesNotSleepOutTheOldOne) {
    // The scheduling half of the pacing promise. A clock paced to slow content
    // is inside a long wait; something then asks it to run faster — a content
    // rate that turned out to be tighter, or the user raising the target FPS.
    // If that wait cannot be cut short, every frame the content produced during
    // it is superseded before it is ever displayed.
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };
    FrameTimer timer([&]() {
        std::lock_guard<std::mutex> guard(mutex);
        ++draws;
        condition.notify_all();
    });
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({ .content_period = 2s });
    timer.Run();
    // Let the timer thread get into the two-second wait.
    std::this_thread::sleep_for(60ms);
    ASSERT_EQ(draws, 0);

    timer.SetFrameDemand({ .content_period = 20ms });
    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 600ms);
    timer.Stop();

    EXPECT_GT(draws, 0) << "the shortened interval never took effect";
    EXPECT_LT(waited.count(), 400)
        << "a tighter content rate must not wait out the previous period";
}

TEST(FrameTimerTest, RaisingTheTargetFpsInterruptsAPacedWait) {
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };
    FrameTimer timer([&]() {
        std::lock_guard<std::mutex> guard(mutex);
        ++draws;
        condition.notify_all();
    });
    timer.SetRequiredFps(1);
    timer.SetFrameDemand({ .content_period = 2s });
    timer.Run();
    std::this_thread::sleep_for(60ms);
    ASSERT_EQ(draws, 0);

    // The user's own setting must not be held hostage by the content's period.
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({});
    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 600ms);
    timer.Stop();

    EXPECT_GT(draws, 0);
    EXPECT_LT(waited.count(), 400);
}

} // namespace
} // namespace wallpaper
