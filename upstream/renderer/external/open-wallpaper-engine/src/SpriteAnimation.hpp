#pragma once
#include <cstdint>
#include <vector>
#include <iostream>
#include <cstdint>
#include <array>
#include <algorithm>
#include <cmath>

#include "Core/Literals.hpp"

namespace wallpaper
{
struct SpriteFrame {
    i32   imageId { 0 };
    float frametime { 0 };
    float x { 0 };
    float y { 0 };
    float width { 1 };
    float height { 1 };
    float rate { 1 }; // real h / w

    std::array<float, 2> xAxis { 1, 0 };
    std::array<float, 2> yAxis { 0, 1 };
};

class SpriteAnimation {
public:
    const auto& GetAnimateFrame(double newtime) {
        if ((m_remainTime -= newtime) < 0.0f) {
            SwitchToNext();
            const auto& frame = m_frames.at((usize)m_curFrame);
            m_remainTime      = frame.frametime;
        }
        const auto& frame = m_frames.at((usize)m_curFrame);
        return frame;
    }
    const auto& SetFrame(double frame) {
        const auto last = static_cast<double>(m_frames.size() - 1);
        m_curFrame = static_cast<idx>(std::clamp(std::floor(frame), 0.0, last));
        m_remainTime = m_frames.at((usize)m_curFrame).frametime;
        return m_frames.at((usize)m_curFrame);
    }
    const auto& GetCurFrame() const { return m_frames.at((usize)m_curFrame); }
    /// A single-frame sprite never advances, so it does not make its pass
    /// time-varying.
    usize FrameCount() const { return m_frames.size(); }
    void        AppendFrame(const SpriteFrame& frame) { m_frames.push_back(frame); }

    usize numFrames() const { return m_frames.size(); }

private:
    void SwitchToNext() {
        if (m_curFrame >= std::ssize(m_frames) - 1)
            m_curFrame = 0;
        else
            m_curFrame++;
    }
    idx    m_curFrame { 0 };
    double m_remainTime { 0 };

    std::vector<SpriteFrame> m_frames;
};
} // namespace wallpaper
