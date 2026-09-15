#pragma once
#include "Particle/ParticleEmitter.h"
#include "wpscene/WPParticleObject.h"
#include "Audio/AudioResponseService.h"

#include <memory>

namespace wallpaper
{
class WPParticleParser {
public:
    static ParticleInitOp genParticleInitOp(const nlohmann::json&);
    static ParticleOperatorOp
    genParticleOperatorOp(const nlohmann::json&,
                          std::shared_ptr<const wpscene::ParticleInstanceoverride>);
    static ParticleEmittOp
    genParticleEmittOp(const wpscene::Emitter&, bool sort = false,
                       std::shared_ptr<const wpscene::ParticleInstanceoverride> override = nullptr,
                       std::function<audio::AudioSpectrumSnapshot()> audio_spectrum      = {});
    static ParticleInitOp
        genOverrideInitOp(std::shared_ptr<const wpscene::ParticleInstanceoverride>);
};
} // namespace wallpaper
