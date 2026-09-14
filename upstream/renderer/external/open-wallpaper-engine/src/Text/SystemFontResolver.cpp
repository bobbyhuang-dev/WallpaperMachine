#include "Text/SystemFontResolver.hpp"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <string>
#include <string_view>

#ifdef __APPLE__
#    include <CoreFoundation/CoreFoundation.h>
#    include <CoreText/CoreText.h>
#endif

namespace wallpaper
{
namespace
{

constexpr std::string_view kSystemFontPrefix = "systemfont_";

std::string SystemFontFamily(std::string_view system_font_key) {
    const auto filename = std::filesystem::path(system_font_key).filename().string();
    std::string family;
    if (std::string_view(filename).starts_with(kSystemFontPrefix)) {
        family = filename.substr(kSystemFontPrefix.size());
    } else {
        family = filename;
    }

    std::string normalized = family;
    std::ranges::transform(normalized, normalized.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    if (normalized == "sansserif" || normalized == "sans-serif") return "Helvetica";
    if (normalized == "serif") return "Times New Roman";
    if (normalized == "monospace" || normalized == "monospaced") return "Menlo";

    return family;
}

#ifdef __APPLE__
template<typename T>
class ScopedCf {
public:
    explicit ScopedCf(T value): m_value(value) {}
    ~ScopedCf() {
        if (m_value != nullptr) CFRelease(m_value);
    }

    ScopedCf(const ScopedCf&)            = delete;
    ScopedCf& operator=(const ScopedCf&) = delete;

    T get() const { return m_value; }

private:
    T m_value { nullptr };
};

std::string CfStringToUtf8(CFStringRef value) {
    if (value == nullptr) return {};

    const CFIndex length   = CFStringGetLength(value);
    const CFIndex max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    if (max_size <= 1) return {};

    std::string output(static_cast<std::size_t>(max_size), '\0');
    if (! CFStringGetCString(value, output.data(), max_size, kCFStringEncodingUTF8)) {
        return {};
    }
    output.resize(std::char_traits<char>::length(output.c_str()));
    return output;
}

std::string CfUrlToPath(CFURLRef url) {
    if (url == nullptr) return {};
    ScopedCf<CFStringRef> path(CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle));
    return CfStringToUtf8(path.get());
}

std::string ResolveAppleSystemFontPath(std::string_view family) {
    if (family.empty()) return {};

    ScopedCf<CFStringRef> family_name(
        CFStringCreateWithBytes(kCFAllocatorDefault,
                                reinterpret_cast<const UInt8*>(family.data()),
                                static_cast<CFIndex>(family.size()),
                                kCFStringEncodingUTF8,
                                false));
    if (family_name.get() == nullptr) return {};

    ScopedCf<CFMutableDictionaryRef> attributes(CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    if (attributes.get() == nullptr) return {};
    CFDictionarySetValue(attributes.get(), kCTFontFamilyNameAttribute, family_name.get());

    ScopedCf<CTFontDescriptorRef> requested_descriptor(
        CTFontDescriptorCreateWithAttributes(attributes.get()));
    if (requested_descriptor.get() == nullptr) return {};

    ScopedCf<CTFontDescriptorRef> matched_descriptor(
        CTFontDescriptorCreateMatchingFontDescriptor(requested_descriptor.get(), nullptr));
    if (matched_descriptor.get() == nullptr) return {};

    ScopedCf<CFTypeRef> url_value(
        CTFontDescriptorCopyAttribute(matched_descriptor.get(), kCTFontURLAttribute));
    return CfUrlToPath(static_cast<CFURLRef>(url_value.get()));
}
#endif

} // namespace

std::string ResolveSystemFontPath(std::string_view system_font_key) {
    const auto family = SystemFontFamily(system_font_key);
    if (family.empty()) return {};

#ifdef __APPLE__
    return ResolveAppleSystemFontPath(family);
#else
    return {};
#endif
}

} // namespace wallpaper
