#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <tuple>
#include <vector>

#include <gtest/gtest.h>
#include <lz4.h>

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "WPPkgFs.hpp"
#include "WPTexImageParser.hpp"
#include "Utils/Algorism.h"

namespace
{
using namespace wallpaper;

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::vector<uint8_t>> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(it->second));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::vector<uint8_t>> m_files;
};

class GuardedReadStream final : public fs::IBinaryStream {
public:
    GuardedReadStream(
        std::vector<uint8_t> data,
        usize max_read_size,
        std::shared_ptr<bool> oversized_read_seen)
        : m_data(std::move(data)),
          m_maxReadSize(max_read_size),
          m_oversizedReadSeen(std::move(oversized_read_seen))
    {}

    usize Read(void* buffer, usize sizeInByte) override {
        if (sizeInByte > m_maxReadSize) *m_oversizedReadSeen = true;
        const auto available = static_cast<usize>(std::max<idx>(0, Size() - m_pos));
        const auto to_read = std::min(sizeInByte, available);
        std::copy(m_data.begin() + m_pos, m_data.begin() + m_pos + static_cast<idx>(to_read),
                  static_cast<uint8_t*>(buffer));
        m_pos += static_cast<idx>(to_read);
        return to_read;
    }

    char* Gets(char* buffer, usize sizeStr) override {
        Read(buffer, sizeStr);
        return buffer;
    }

    idx Tell() const override { return m_pos; }

    bool SeekSet(idx offset) override {
        if (!InArea(offset)) return false;
        m_pos = offset;
        return true;
    }

    bool SeekCur(idx offset) override { return SeekSet(m_pos + offset); }
    bool SeekEnd(idx offset) override { return SeekSet(Size() + offset); }
    isize Size() const override { return static_cast<isize>(m_data.size()); }

protected:
    usize Write_impl(const void*, usize) override { return 0; }

private:
    bool InArea(idx pos) const { return pos >= 0 && pos <= Size(); }

    std::vector<uint8_t> m_data;
    idx m_pos { 0 };
    usize m_maxReadSize { 0 };
    std::shared_ptr<bool> m_oversizedReadSeen;
};

class GuardedMemoryFs final : public fs::Fs {
public:
    GuardedMemoryFs(
        std::vector<uint8_t> tex,
        usize max_read_size,
        std::shared_ptr<bool> oversized_read_seen)
        : m_tex(std::move(tex)),
          m_maxReadSize(max_read_size),
          m_oversizedReadSeen(std::move(oversized_read_seen))
    {}

    bool Contains(std::string_view path) const override {
        return path == "/materials/sample.tex";
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        if (!Contains(path)) return nullptr;
        return std::make_shared<GuardedReadStream>(
            std::vector<uint8_t>(m_tex),
            m_maxReadSize,
            m_oversizedReadSeen);
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::vector<uint8_t> m_tex;
    usize m_maxReadSize { 0 };
    std::shared_ptr<bool> m_oversizedReadSeen;
};

class Bytes {
public:
    void Stamp(char kind, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "TEX%c%04d", kind, version);
        Append(stamp, sizeof(stamp));
    }

    void I32(int32_t value) { Append(&value, sizeof(value)); }
    void U32(uint32_t value) { Append(&value, sizeof(value)); }
    void F32(float value) { Append(&value, sizeof(value)); }

    void Raw(std::span<const uint8_t> bytes) {
        m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
    }

    std::vector<uint8_t> Take() { return std::move(m_bytes); }

private:
    void Append(const void* data, std::size_t size) {
        const auto* p = static_cast<const uint8_t*>(data);
        m_bytes.insert(m_bytes.end(), p, p + size);
    }

    std::vector<uint8_t> m_bytes;
};

constexpr uint32_t kSpriteFlag = 1u << 2;
constexpr uint32_t kVideoFlag = 1u << 5;

std::vector<uint8_t> Png1x1() {
    return {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
        0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
        0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
}

std::vector<uint8_t> Bmp1x1() {
    return {
        0x42, 0x4d, 0x3a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00,
        0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
        0x00, 0x00, 0x13, 0x0b, 0x00, 0x00, 0x13, 0x0b, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
    };
}

std::vector<uint8_t> Gif1x1() {
    return {
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
    };
}

std::vector<uint8_t> JpegMarkerPayload() {
    return { 0xff, 0xd8, 0xff, 0xd9 };
}

std::vector<uint8_t> TiffMarkerPayload() {
    return { 'I', 'I', 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00 };
}

std::vector<uint8_t> Mp4MarkerPayload() {
    return {
        0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p',
        'i', 's', 'o', 'm', 0x00, 0x00, 0x02, 0x00,
    };
}

std::vector<uint8_t> WebmMarkerPayload() {
    return { 0x1a, 0x45, 0xdf, 0xa3, 0x42, 0x86, 0x81, 0x01 };
}

std::vector<uint8_t> BuildTex(
    int texb,
    int32_t image_type,
    int32_t reserved,
    std::span<const uint8_t> payload,
    uint32_t flags = 0,
    int32_t mip_count = 1)
{
    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(flags);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', texb);
    b.I32(1);
    if (texb >= 3) b.I32(image_type);
    if (texb >= 4) b.I32(reserved);
    b.I32(mip_count);
    if (mip_count > 0) {
        b.I32(1);
        b.I32(1);
        if (texb > 1) {
            b.I32(0);
            b.I32(0);
        }
        b.I32(static_cast<int32_t>(payload.size()));
        b.Raw(payload);
    }
    return b.Take();
}

std::vector<uint8_t> BuildTexWithDeclaredPayloadSize(int32_t src_size) {
    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(0);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.I32(0);
    b.I32(src_size);
    return b.Take();
}

std::vector<uint8_t> BuildCompressedUnknownTex(
    std::span<const uint8_t> decompressed_payload,
    uint32_t                 flags = 0)
{
    std::vector<uint8_t> compressed(static_cast<std::size_t>(
        LZ4_compressBound(static_cast<int>(decompressed_payload.size()))));
    const int compressed_size = LZ4_compress_default(
        reinterpret_cast<const char*>(decompressed_payload.data()),
        reinterpret_cast<char*>(compressed.data()),
        static_cast<int>(decompressed_payload.size()),
        static_cast<int>(compressed.size()));
    if (compressed_size <= 0) return {};
    compressed.resize(static_cast<std::size_t>(compressed_size));

    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(flags);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(static_cast<int32_t>(decompressed_payload.size()));
    b.I32(compressed_size);
    b.Raw(compressed);
    return b.Take();
}

std::vector<uint8_t> BuildSpriteWithInvalidFrames(bool empty_mips) {
    const std::vector<uint8_t> raw { 0xff, 0x00, 0x00, 0xff };
    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(kSpriteFlag);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 2);
    b.I32(1);
    b.I32(empty_mips ? 0 : 1);
    if (!empty_mips) {
        b.I32(1);
        b.I32(1);
        b.I32(0);
        b.I32(0);
        b.I32(static_cast<int32_t>(raw.size()));
        b.Raw(raw);
    }
    b.Stamp('S', 2);
    b.I32(3);
    for (const int32_t image_id : { -1, 2, 0 }) {
        b.I32(image_id);
        b.F32(0.1f);
        b.F32(0.0f);
        b.F32(0.0f);
        b.F32(1.0f);
        b.F32(0.0f);
        b.F32(0.0f);
        b.F32(1.0f);
    }
    return b.Take();
}

WPTexImageParser MakeParser(fs::VFS& vfs, std::vector<uint8_t> tex) {
    auto files = std::map<std::string, std::vector<uint8_t>> {
        { "/materials/sample.tex", std::move(tex) },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    return WPTexImageParser(&vfs);
}

struct PkgEntry {
    std::string path;
    std::string payload;
};

class TempPkg {
public:
    explicit TempPkg(std::vector<PkgEntry> entries) {
        const auto unique = "owe_pkg_case_test_" + std::to_string(s_nextId++) + ".pkg";
        m_path = std::filesystem::temp_directory_path() / unique;

        std::ofstream out(m_path, std::ios::binary | std::ios::trunc);
        auto write_i32 = [&](int32_t value) {
            out.write(reinterpret_cast<const char*>(&value), sizeof(value));
        };
        const std::string version = "PKGV0001";
        write_i32(static_cast<int32_t>(version.size()));
        out.write(version.data(), static_cast<std::streamsize>(version.size()));
        write_i32(static_cast<int32_t>(entries.size()));

        int32_t offset = 0;
        for (const auto& entry : entries) {
            write_i32(static_cast<int32_t>(entry.path.size()));
            out.write(entry.path.data(), static_cast<std::streamsize>(entry.path.size()));
            write_i32(offset);
            write_i32(static_cast<int32_t>(entry.payload.size()));
            offset += static_cast<int32_t>(entry.payload.size());
        }
        for (const auto& entry : entries) {
            out.write(entry.payload.data(), static_cast<std::streamsize>(entry.payload.size()));
        }
    }

    ~TempPkg() {
        if (!m_path.empty()) {
            std::error_code ec;
            std::filesystem::remove(m_path, ec);
        }
    }

    const std::filesystem::path& path() const { return m_path; }

private:
    std::filesystem::path m_path;
    inline static int s_nextId { 0 };
};

std::string ReadPkgFile(fs::WPPkgFs& pkg, std::string_view path) {
    auto stream = pkg.Open(path);
    if (!stream) return {};
    return stream->ReadAllStr();
}

} // namespace

TEST(TexSchema, TexbVersionsReadExpectedHeaderLayout) {
    for (const int texb : { 1, 2, 3, 4 }) {
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(texb, static_cast<int32_t>(ImageType::PNG), 0, Png1x1()));
        const auto header = parser.ParseHeader("sample");
        EXPECT_EQ(header.extraHeader.at("texb").val, texb);
        EXPECT_EQ(header.count, 1);
        EXPECT_EQ(header.width, 1);
        EXPECT_EQ(header.height, 1);
        if (texb >= 3) EXPECT_EQ(header.type, ImageType::PNG);
        else EXPECT_EQ(header.type, ImageType::UNKNOWN);
    }
}

TEST(TexSchema, Texb4ReservedFieldDoesNotMarkVideoOrMisalignBody) {
    fs::VFS vfs;
    auto parser = MakeParser(
        vfs,
        BuildTex(4, static_cast<int32_t>(ImageType::PNG), 12345, Png1x1()));

    const auto header = parser.ParseHeader("sample");
    EXPECT_FALSE(header.isVideo);
    EXPECT_EQ(header.type, ImageType::PNG);
    EXPECT_EQ(header.mipmap_pow2, algorism::IsPowOfTwo(1u));

    const auto image = parser.Parse("sample");
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    EXPECT_EQ(image->slots[0].width, 1);
    EXPECT_EQ(image->slots[0].height, 1);
}

TEST(TexSchema, UnknownImageTypeUsesMagicByteFallbackForDecodableContainers) {
    for (const auto& [label, payload, expected] : {
             std::tuple { "png", Png1x1(), ImageType::PNG },
             std::tuple { "gif", Gif1x1(), ImageType::GIF },
         }) {
        SCOPED_TRACE(label);
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, payload));
        const auto image = parser.Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->header.type, expected);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].mipmaps[0].size, 4);
    }
}

TEST(TexSchema, UnknownImageTypeSniffsNonDecodedImageMarkersWithoutCrashing) {
    for (const auto& [label, payload, expected] : {
             std::tuple { "jpeg", JpegMarkerPayload(), ImageType::JPEG },
             std::tuple { "bmp", Bmp1x1(), ImageType::BMP },
             std::tuple { "tiff", TiffMarkerPayload(), ImageType::TIFF },
         }) {
        SCOPED_TRACE(label);
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, payload));
        const auto header = parser.ParseHeader("sample");
        EXPECT_EQ(header.type, expected);
    }
}

TEST(TexSchema, Mp4AndWebmFallbackMarksEmbeddedVideo) {
    for (const auto& [label, payload] : {
             std::tuple { "mp4", Mp4MarkerPayload() },
             std::tuple { "webm", WebmMarkerPayload() },
         }) {
        SCOPED_TRACE(label);
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, payload));
        const auto header = parser.ParseHeader("sample");
        EXPECT_TRUE(header.isVideo);
        EXPECT_EQ(header.type, ImageType::UNKNOWN);
    }
}

TEST(TexSchema, SpriteFramesWithInvalidImageIdsAreSkipped) {
    fs::VFS vfs;
    auto parser = MakeParser(vfs, BuildSpriteWithInvalidFrames(false));

    const auto header = parser.ParseHeader("sample");
    EXPECT_TRUE(header.isSprite);
    ASSERT_EQ(header.spriteAnim.numFrames(), 1u);
    EXPECT_EQ(header.spriteAnim.GetCurFrame().imageId, 0);
}

TEST(TexSchema, SpriteFrameParsingGuardsEmptyMipSections) {
    fs::VFS vfs;
    auto parser = MakeParser(vfs, BuildSpriteWithInvalidFrames(true));

    const auto header = parser.ParseHeader("sample");
    EXPECT_TRUE(header.isSprite);
    EXPECT_EQ(header.spriteAnim.numFrames(), 0u);
}

TEST(TexSchema, NonSpriteHeaderGuardsEmptyMipSections) {
    fs::VFS vfs;
    auto parser = MakeParser(
        vfs,
        BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, {}, 0, 0));

    const auto header = parser.ParseHeader("sample");
    EXPECT_EQ(header.count, 1);
    EXPECT_FALSE(header.mipmap_pow2);
    EXPECT_FALSE(header.mipmap_larger);
    EXPECT_FALSE(header.isVideo);
}

TEST(TexSchema, HeaderSniffRejectsOversizedPayloadWithoutAllocating) {
    fs::VFS vfs;
    auto oversized_read_seen = std::make_shared<bool>(false);
    EXPECT_TRUE(vfs.Mount(
        "/assets",
        std::make_unique<GuardedMemoryFs>(
            BuildTexWithDeclaredPayloadSize(4096),
            64,
            oversized_read_seen)));
    WPTexImageParser parser(&vfs);

    ImageHeader header;
    ASSERT_NO_THROW(header = parser.ParseHeader("sample"));
    EXPECT_EQ(header.type, ImageType::UNKNOWN);
    EXPECT_FALSE(header.isVideo);
    EXPECT_FALSE(*oversized_read_seen);
}

TEST(TexSchema, HeaderSniffDoesNotDecompressCompressedPayloadPrefixes) {
    std::vector<uint8_t> decompressed(4096, 0);
    const auto marker = Mp4MarkerPayload();
    std::copy(marker.begin(), marker.end(), decompressed.begin());

    fs::VFS vfs;
    auto oversized_read_seen = std::make_shared<bool>(false);
    EXPECT_TRUE(vfs.Mount(
        "/assets",
        std::make_unique<GuardedMemoryFs>(
            BuildCompressedUnknownTex(decompressed),
            64,
            oversized_read_seen)));
    WPTexImageParser parser(&vfs);

    ImageHeader header;
    ASSERT_NO_THROW(header = parser.ParseHeader("sample"));
    EXPECT_EQ(header.type, ImageType::UNKNOWN);
    EXPECT_FALSE(header.isVideo);
    EXPECT_FALSE(*oversized_read_seen);
}

TEST(TexSchema, FlaggedVideoUnknownTypeUsesExistingMetadataPath) {
    std::vector<uint8_t> decompressed(4096);
    for (std::size_t i = 0; i < decompressed.size(); ++i) {
        decompressed[i] = static_cast<uint8_t>((i * 37u + i / 3u) & 0xffu);
    }
    const auto marker = Mp4MarkerPayload();
    std::copy(marker.begin(), marker.end(), decompressed.begin());

    fs::VFS vfs;
    auto oversized_read_seen = std::make_shared<bool>(false);
    EXPECT_TRUE(vfs.Mount(
        "/assets",
        std::make_unique<GuardedMemoryFs>(
            BuildCompressedUnknownTex(decompressed, kVideoFlag),
            64,
            oversized_read_seen)));
    WPTexImageParser parser(&vfs);

    ImageHeader header;
    ASSERT_NO_THROW(header = parser.ParseHeader("sample"));
    EXPECT_TRUE(header.isVideo);
    EXPECT_TRUE(*oversized_read_seen);
}

TEST(PkgFs, ContainsAndOpenResolvePackagePathsCaseInsensitively) {
    TempPkg pkg_file({ { "Materials/Foo.TEX", "payload" } });
    auto pkg = fs::WPPkgFs::CreatePkgFs(pkg_file.path().string());
    ASSERT_NE(pkg, nullptr);

    EXPECT_TRUE(pkg->Contains("/materials/foo.tex"));
    EXPECT_TRUE(pkg->Contains("/MATERIALS/FOO.TEX"));

    auto stream = pkg->Open("/materials/foo.tex");
    ASSERT_NE(stream, nullptr);
    EXPECT_EQ(stream->ReadAllStr(), "payload");
}

TEST(PkgFs, ExactPathWinsWhenPackageContainsCaseFoldCollision) {
    TempPkg pkg_file({
        { "Materials/Foo.TEX", "upper" },
        { "materials/foo.tex", "lower" },
    });
    auto pkg = fs::WPPkgFs::CreatePkgFs(pkg_file.path().string());
    ASSERT_NE(pkg, nullptr);

    EXPECT_EQ(ReadPkgFile(*pkg, "/Materials/Foo.TEX"), "upper");
    EXPECT_EQ(ReadPkgFile(*pkg, "/materials/foo.tex"), "lower");
    EXPECT_TRUE(pkg->Contains("/MATERIALS/FOO.TEX"));
}
