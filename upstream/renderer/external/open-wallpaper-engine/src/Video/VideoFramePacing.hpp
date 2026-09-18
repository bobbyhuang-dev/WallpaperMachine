#pragma once

#include <cstddef>
#include <cstdint>

namespace wallpaper::video
{

/// A container's declared frame rate, as a rational, exactly as libavformat
/// reports it. `23.976` and `29.97` are `24000/1001` and `30000/1001`; keeping
/// the ratio avoids rounding a rate that was never a terminating decimal.
struct FrameRateRatio {
    std::int64_t num { 0 };
    std::int64_t den { 0 };
};

/// Shortest period any of the declared rates implies, in seconds, or 0 when
/// none of them is usable.
///
/// The shortest period is the safe one: pacing on a longer period skips the
/// frames inside a tighter gap, while pacing on a shorter one only renders more
/// often than needed. `avg_frame_rate` is an average and `r_frame_rate` is an
/// estimate, so neither is evidence about a specific gap — this value is a
/// bound to combine with observed timestamps, never a promise on its own.
[[nodiscard]] double ShortestMetadataPeriodSeconds(const FrameRateRatio* rates, std::size_t count);

/// Shortest gap actually observed between decoded frames.
///
/// Container metadata cannot prove how far apart two particular frames are. A
/// variable-frame-rate clip, a clip with broken metadata and a clip with a
/// non-zero start timestamp all report rates that do not describe their local
/// timing. This accumulates evidence from the decoder's real presentation
/// timestamps and reports nothing until it has enough of it, so an unproven
/// stream keeps the fixed cadence instead of being paced on a guess.
class VideoFramePacingEstimator {
public:
    /// Deltas needed before a period is reported at all. Below this the answer
    /// is "unknown", which the frame clock reads as "keep the fixed cadence".
    static constexpr std::uint64_t kMinimumSamples = 8;

    void Reset(double metadata_period_seconds);

    /// Records one decoded frame. `loop_index` and `seek_ticket` identify the
    /// continuous run the frame belongs to: a delta measured across a loop seam
    /// or a seek describes the seam, not the content, and is discarded.
    void Observe(double absolute_seconds, std::uint64_t loop_index, std::uint64_t seek_ticket);

    /// Period to pace on, in seconds, or 0 when the content cannot prove one.
    /// Never longer than the shortest declared or observed gap, and
    /// monotonically non-increasing for as long as the source lives.
    [[nodiscard]] double PeriodSeconds() const;

    [[nodiscard]] double ObservedPeriodSeconds() const { return m_observed_period; }
    [[nodiscard]] double MetadataPeriodSeconds() const { return m_metadata_period; }
    [[nodiscard]] std::uint64_t SampleCount() const { return m_samples; }

private:
    double        m_metadata_period { 0.0 };
    double        m_observed_period { 0.0 };
    std::uint64_t m_samples { 0 };
    bool          m_has_previous { false };
    double        m_previous_absolute { 0.0 };
    std::uint64_t m_previous_loop { 0 };
    std::uint64_t m_previous_seek_ticket { 0 };
};

/// Wall-clock period at which the frame clock has to tick for this content, or
/// 0 when it cannot be proven.
///
/// The source period is measured on the media's own timeline. Playback speed
/// maps that timeline onto the wall clock: at 2x a 30 fps clip delivers a new
/// frame every 16.7 ms of real time, so pacing on 33.3 ms would drop every
/// other frame. A non-positive or non-finite rate reports unknown rather than
/// inventing a period.
[[nodiscard]] double ResolveContentPeriodSeconds(double source_period_seconds,
                                                 double playback_rate);

/// Whether an environment value asks for demand-driven pacing to be switched
/// on. Null, empty, "0" and "false" all mean off.
///
/// Pacing is **opt-in**, and the reason is a bound that cannot be removed
/// without an event-driven clock. The content period only reaches the frame
/// clock from `refreshFrameDemand`, which runs after a completed frame. A
/// source whose rate turns out to be tighter than the interval currently being
/// waited out therefore produces frames that are superseded before the next
/// frame boundary: up to `interval / period - 1` of them, not one. The safe
/// baseline — ticking at the configured ceiling — is the default, and this
/// switch is also the A/B entry point, so a comparison measures one scheduling
/// strategy in one binary rather than two builds. It covers a scheduling
/// strategy only; it never restores a resource-lifetime or decode-correctness
/// defect.
[[nodiscard]] bool ContentPacingEnabledByEnvironment(const char* value);

/// Process-wide content-pacing switch, settable from the app's settings rather
/// than only from the environment.
///
/// The environment variable still seeds it at first read, so an existing debug
/// workflow keeps working; a later explicit call wins, because a persisted user
/// setting has to be able to override an inherited environment.
void SetContentPacingEnabled(bool enabled);
[[nodiscard]] bool ContentPacingEnabled();

struct VideoFrameSelection {
    /// A newer decoded frame became the displayed frame.
    bool selected { false };
    /// The frame already on screen was served again.
    bool reused { false };
    /// Decoded frames that were superseded before they were ever displayed.
    std::uint64_t skipped { 0 };
};

/// Turns the sequence of displayed frame generations into the three outcomes a
/// pacing change can produce. Generations are assigned in decode order, so a
/// gap between two displayed generations is exactly the number of decoded
/// frames that never reached the screen — which is the failure a demand-driven
/// clock has to be falsifiable against.
class VideoFrameSelectionTracker {
public:
    VideoFrameSelection Observe(std::uint64_t generation);
    void                Reset();

private:
    std::uint64_t m_last_generation { 0 };
    bool          m_has_last { false };
};

} // namespace wallpaper::video
