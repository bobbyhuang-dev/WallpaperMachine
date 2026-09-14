#pragma once

#include <vector>

namespace wallpaper
{

struct ScalarAnimationKeyframe
{
    double frame { 0.0 };
    float  value { 0.0f };
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
    std::vector<ScalarAnimationKeyframe> keyframes;

    [[nodiscard]] float Evaluate(double seconds) const;
};

} // namespace wallpaper
