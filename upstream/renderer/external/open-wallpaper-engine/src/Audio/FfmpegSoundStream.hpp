#pragma once

#include "Audio/SoundManager.h"

#include <filesystem>
#include <memory>
#include <string>

namespace wallpaper::fs
{
class IBinaryStream;
}

namespace wallpaper::audio
{

std::unique_ptr<SoundStream> CreateFfmpegSoundStream(const std::filesystem::path& media_path,
                                                     std::string* error,
                                                     SoundStream::Options options = {},
                                                     bool audio_optional = false);
std::unique_ptr<SoundStream> CreateFfmpegSoundStream(std::shared_ptr<fs::IBinaryStream> stream,
                                                     std::string* error,
                                                     SoundStream::Options options = {});

} // namespace wallpaper::audio
