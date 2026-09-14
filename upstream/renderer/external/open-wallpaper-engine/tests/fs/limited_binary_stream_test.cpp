#include "Fs/LimitedBinaryStream.h"
#include "Fs/MemBinaryStream.h"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <memory>

namespace wallpaper::fs
{
namespace
{

TEST(LimitedBinaryStreamTest, RewindAndSeekEndSupportBeginningOfWindow) {
    std::array<uint8_t, 8> data { 10, 11, 12, 13, 14, 15, 16, 17 };
    auto source = std::make_shared<MemBinaryStream>(std::vector<uint8_t>(data.begin(), data.end()));
    LimitedBinaryStream stream(source, 2, 4);

    EXPECT_TRUE(stream.SeekSet(0));
    EXPECT_EQ(stream.Tell(), 0);

    std::array<uint8_t, 4> buffer {};
    EXPECT_EQ(stream.Read(buffer.data(), buffer.size()), buffer.size());
    EXPECT_EQ(buffer[0], 12u);
    EXPECT_EQ(buffer[3], 15u);

    EXPECT_TRUE(stream.Rewind());
    EXPECT_EQ(stream.Tell(), 0);

    EXPECT_TRUE(stream.SeekEnd(0));
    EXPECT_EQ(stream.Tell(), 4);
    EXPECT_EQ(stream.Read(buffer.data(), buffer.size()), 0u);
}

} // namespace
} // namespace wallpaper::fs
