#pragma once

#include "WPShaderParser.hpp"

#include <string>

namespace wallpaper::shader
{

inline void ApplyTextureFormatCombo(Combos& combos, usize slot, TextureFormat format)
{
    std::string combo_name = "TEX" + std::to_string(slot) + "FORMAT";
    switch (format) {
    case TextureFormat::R8:
        combos[combo_name] = "9";
        break;
    case TextureFormat::RG8:
        combos[combo_name] = "8";
        break;
    default:
        break;
    }
}

} // namespace wallpaper::shader
