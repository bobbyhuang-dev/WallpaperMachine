#pragma once
#include "Interface/IImageParser.h"
#include "Fs/VFS.h"

#include <string>

namespace wallpaper
{

class WPTexImageParser : public IImageParser {
public:
    WPTexImageParser(fs::VFS* vfs): m_vfs(vfs) {}
    virtual ~WPTexImageParser() = default;

    std::shared_ptr<Image> Parse(const std::string&) override;
    ImageHeader            ParseHeader(const std::string&) override;

private:
    std::shared_ptr<Image> ParseLooseAsset(const std::string& name);
    ImageHeader            ParseLooseAssetHeader(const std::string& name);

    fs::VFS* m_vfs;
};
} // namespace wallpaper
