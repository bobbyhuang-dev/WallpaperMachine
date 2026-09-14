#include "WPPkgFs.hpp"
#include "Utils/Logging.h"
#include "Fs/LimitedBinaryStream.h"
#include "Fs/CBinaryStream.h"
#include <cctype>
#include <vector>

using namespace wallpaper;
using namespace wallpaper::fs;

namespace
{
std::string ReadSizedString(IBinaryStream& f) {
    idx ilen = f.ReadInt32();
    assert(ilen >= 0);

    usize       len = (usize)ilen;
    std::string result;
    result.resize(len);
    f.Read(result.data(), len);
    return result;
}

std::string LowerPath(std::string_view path) {
    std::string lowered(path);
    for (auto& ch : lowered) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return lowered;
}
} // namespace

std::unique_ptr<WPPkgFs> WPPkgFs::CreatePkgFs(std::string_view pkgpath) {
    auto ppkg = fs::CreateCBinaryStream(pkgpath);
    if (! ppkg) return nullptr;

    auto&       pkg = *ppkg;
    std::string ver = ReadSizedString(pkg);
    LOG_INFO("pkg version: %s", ver.data());

    std::vector<PkgFile> pkgfiles;
    i32                  entryCount = pkg.ReadInt32();
    for (i32 i = 0; i < entryCount; i++) {
        std::string path   = "/" + ReadSizedString(pkg);
        idx         offset = pkg.ReadInt32();
        idx         length = pkg.ReadInt32();
        pkgfiles.push_back({ path, offset, length });
    }
    auto pkgfs       = std::unique_ptr<WPPkgFs>(new WPPkgFs());
    pkgfs->m_pkgPath = pkgpath;
    idx headerSize   = pkg.Tell();
    for (auto& el : pkgfiles) {
        el.offset += headerSize;
        const auto path = el.path;
        pkgfs->m_files.insert({ path, el });
        pkgfs->m_caseFoldedFiles.insert({ LowerPath(path), path });
    }
    return pkgfs;
}

bool WPPkgFs::Contains(std::string_view path) const {
    const std::string exact_path(path);
    return m_files.count(exact_path) > 0 || m_caseFoldedFiles.count(LowerPath(path)) > 0;
}

std::shared_ptr<IBinaryStream> WPPkgFs::Open(std::string_view path) {
    auto pkg = fs::CreateCBinaryStream(m_pkgPath);
    if (! pkg) return nullptr;
    auto exact = m_files.find(std::string(path));
    if (exact != m_files.end()) {
        const auto& file = exact->second;
        return std::make_shared<LimitedBinaryStream>(pkg, file.offset, file.length);
    }
    auto canonical = m_caseFoldedFiles.find(LowerPath(path));
    if (canonical != m_caseFoldedFiles.end()) {
        const auto& file = m_files.at(canonical->second);
        return std::make_shared<LimitedBinaryStream>(pkg, file.offset, file.length);
    }
    return nullptr;
}

std::shared_ptr<IBinaryStreamW> WPPkgFs::OpenW(std::string_view) { return nullptr; }
