#pragma once

#include <string>
#include <vector>

namespace wallpaper
{
struct ScalarAnimationHandle
{
    double x { 0.0 };
    double y { 0.0 };
    bool enabled { false };
};


struct ScalarAnimationKeyframe
{
    double frame { 0.0 };
    float  value { 0.0f };
    ScalarAnimationHandle back;
    ScalarAnimationHandle front;
};

enum class ScalarAnimationMode
{
    Single,
    Loop,
};

struct ScalarAnimation
{
    float                               initial_value { 0.0f };
    double                              fps { 0.0 };
    double                              length_frames { 0.0 };
    ScalarAnimationMode                 mode { ScalarAnimationMode::Single };
    std::string                         name;
    bool                                start_paused { false };
    std::vector<ScalarAnimationKeyframe> keyframes;

    [[nodiscard]] float Evaluate(double seconds) const;
    [[nodiscard]] double FrameCount() const;
};

struct ScalarAnimationPlayback
{
    ScalarAnimation animation;
    double frame { 0.0 };
    double rate { 1.0 };
    bool playing { false };

    void Advance(double seconds);
    void Play();
    void Stop();
    void SetFrame(double value);
    [[nodiscard]] float Value() const;
};

} // namespace wallpaper
