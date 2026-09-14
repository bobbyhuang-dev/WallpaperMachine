#include "Audio/FfmpegSoundStream.hpp"
#include "Fs/IBinaryStream.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper::audio
{
namespace
{

class MemoryBinaryStream final : public fs::IBinaryStream {
public:
    explicit MemoryBinaryStream(std::vector<uint8_t> data)
        : m_data(std::move(data))
    {
    }

    usize Read(void* buffer, usize sizeInByte) override
    {
        const auto bytes_to_read = std::min<usize>(
            sizeInByte,
            static_cast<usize>(m_data.size() - m_position));
        if (bytes_to_read > 0) {
            std::memcpy(buffer, m_data.data() + m_position, bytes_to_read);
            m_position += bytes_to_read;
        }
        return bytes_to_read;
    }

    char* Gets(char* buffer, usize sizeStr) override
    {
        if (buffer == nullptr || sizeStr == 0) return buffer;

        usize copied = 0;
        while (copied + 1 < sizeStr && m_position < m_data.size()) {
            const auto byte = static_cast<char>(m_data[m_position++]);
            buffer[copied++] = byte;
            if (byte == '\n') break;
        }
        buffer[copied] = '\0';
        return copied == 0 ? nullptr : buffer;
    }

    idx Tell() const override { return static_cast<idx>(m_position); }

    bool SeekSet(idx offset) override
    {
        if (!IsValidOffset(offset)) return false;
        m_position = static_cast<std::size_t>(offset);
        return true;
    }

    bool SeekCur(idx offset) override
    {
        return SeekSet(static_cast<idx>(m_position) + offset);
    }

    bool SeekEnd(idx offset) override
    {
        return SeekSet(static_cast<idx>(m_data.size()) + offset);
    }

    isize Size() const override { return static_cast<isize>(m_data.size()); }

protected:
    usize Write_impl(const void*, usize) override { return 0; }

private:
    bool IsValidOffset(idx offset) const
    {
        return offset >= 0 && static_cast<std::size_t>(offset) <= m_data.size();
    }

    std::vector<uint8_t> m_data;
    std::size_t          m_position { 0 };
};

void AppendFourCc(std::vector<uint8_t>& bytes, const std::array<char, 4>& value)
{
    bytes.insert(bytes.end(), value.begin(), value.end());
}

void AppendU16Le(std::vector<uint8_t>& bytes, uint16_t value)
{
    bytes.push_back(static_cast<uint8_t>(value & 0xffu));
    bytes.push_back(static_cast<uint8_t>((value >> 8u) & 0xffu));
}

void AppendU32Le(std::vector<uint8_t>& bytes, uint32_t value)
{
    bytes.push_back(static_cast<uint8_t>(value & 0xffu));
    bytes.push_back(static_cast<uint8_t>((value >> 8u) & 0xffu));
    bytes.push_back(static_cast<uint8_t>((value >> 16u) & 0xffu));
    bytes.push_back(static_cast<uint8_t>((value >> 24u) & 0xffu));
}

std::vector<uint8_t> MakeWavS16Mono(uint32_t sample_rate, uint16_t frame_count)
{
    constexpr uint16_t channel_count = 1;
    constexpr uint16_t bits_per_sample = 16;
    constexpr uint16_t bytes_per_sample = bits_per_sample / 8;
    const uint32_t data_size = static_cast<uint32_t>(frame_count) * bytes_per_sample;
    const uint32_t byte_rate = sample_rate * channel_count * bytes_per_sample;
    const uint16_t block_align = channel_count * bytes_per_sample;

    std::vector<uint8_t> bytes;
    bytes.reserve(44u + data_size);
    AppendFourCc(bytes, { 'R', 'I', 'F', 'F' });
    AppendU32Le(bytes, 36u + data_size);
    AppendFourCc(bytes, { 'W', 'A', 'V', 'E' });
    AppendFourCc(bytes, { 'f', 'm', 't', ' ' });
    AppendU32Le(bytes, 16);
    AppendU16Le(bytes, 1);
    AppendU16Le(bytes, channel_count);
    AppendU32Le(bytes, sample_rate);
    AppendU32Le(bytes, byte_rate);
    AppendU16Le(bytes, block_align);
    AppendU16Le(bytes, bits_per_sample);
    AppendFourCc(bytes, { 'd', 'a', 't', 'a' });
    AppendU32Le(bytes, data_size);

    for (uint16_t frame = 0; frame < frame_count; ++frame) {
        const int16_t sample = (frame % 32u) < 16u ? 12'000 : -12'000;
        AppendU16Le(bytes, static_cast<uint16_t>(sample));
    }

    return bytes;
}

TEST(FfmpegSoundStreamTest, VfsBackedStreamDecodesPcm)
{
    auto stream = std::make_shared<MemoryBinaryStream>(MakeWavS16Mono(12'000, 512));
    std::string error;

    auto sound = CreateFfmpegSoundStream(stream, &error);

    ASSERT_NE(sound, nullptr) << error;
    sound->PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 256> output {};
    const auto frames = sound->NextPcmData(output.data(), 128);

    EXPECT_GT(frames, 0u);
    EXPECT_TRUE(std::any_of(output.begin(), output.end(), [](float sample) {
        return sample != 0.0f;
    }));
}

TEST(FfmpegSoundStreamTest, NonLoopingVfsStreamReportsEndOfFile)
{
    auto stream = std::make_shared<MemoryBinaryStream>(MakeWavS16Mono(12'000, 16));
    std::string error;

    auto sound = CreateFfmpegSoundStream(stream, &error, { .loop = false });

    ASSERT_NE(sound, nullptr) << error;
    sound->PassDesc({ .channels = 1, .sampleRate = 12'000 });

    std::array<float, 64> output {};
    EXPECT_GT(sound->NextPcmData(output.data(), 16), 0u);

    bool reached_eof = false;
    for (int attempt = 0; attempt < 8; ++attempt) {
        std::fill(output.begin(), output.end(), 1.0f);
        const auto frames = sound->NextPcmData(output.data(), 16);
        if (frames == 0u) {
            reached_eof = true;
            EXPECT_TRUE(std::all_of(output.begin(), output.begin() + 16, [](float sample) {
                return sample == 0.0f;
            }));
            break;
        }
    }

    EXPECT_TRUE(reached_eof);
}

TEST(FfmpegSoundStreamTest, DefaultVfsStreamLoopsForVideoWallpaperAudio)
{
    auto stream = std::make_shared<MemoryBinaryStream>(MakeWavS16Mono(12'000, 16));
    std::string error;

    auto sound = CreateFfmpegSoundStream(stream, &error);

    ASSERT_NE(sound, nullptr) << error;
    sound->PassDesc({ .channels = 1, .sampleRate = 12'000 });

    std::array<float, 16> output {};
    bool                  produced_after_first_read = false;
    EXPECT_GT(sound->NextPcmData(output.data(), 16), 0u);
    for (int attempt = 0; attempt < 8; ++attempt) {
        std::fill(output.begin(), output.end(), 0.0f);
        const auto frames = sound->NextPcmData(output.data(), 16);
        if (frames > 0u &&
            std::any_of(output.begin(), output.end(), [](float sample) {
                return sample != 0.0f;
            })) {
            produced_after_first_read = true;
            break;
        }
    }

    EXPECT_TRUE(produced_after_first_read);
}

TEST(FfmpegSoundStreamTest, InvalidVfsStreamFailsGracefully)
{
    auto stream = std::make_shared<MemoryBinaryStream>(std::vector<uint8_t> { 1, 2, 3, 4 });
    std::string error;

    auto sound = CreateFfmpegSoundStream(stream, &error);

    EXPECT_EQ(sound, nullptr);
    EXPECT_FALSE(error.empty());
}

TEST(FfmpegSoundStreamTest, SoundManagerNoLongerUsesMiniaudioDecoder)
{
    const auto source_path = std::filesystem::path(__FILE__)
                                 .parent_path()
                                 .parent_path()
                                 .parent_path() /
                             "src/Audio/SoundManager.cpp";
    std::ifstream source_file(source_path);
    ASSERT_TRUE(source_file.is_open()) << source_path;

    const std::string source(
        (std::istreambuf_iterator<char>(source_file)),
        std::istreambuf_iterator<char>());

    EXPECT_EQ(source.find("miniaudio::Decoder"), std::string::npos);
}

} // namespace
} // namespace wallpaper::audio
