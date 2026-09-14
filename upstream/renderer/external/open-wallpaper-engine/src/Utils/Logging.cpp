#include "Utils/Logging.h"
#include <cstdio>
#include <cstdarg>
#include <filesystem>
#include <atomic>
#include <vector>

#include "Utils/Sha.hpp"

constexpr const char* level_names[] = { "INFO", "ERROR" };
constexpr const char* level_fmt[]   = { "%-5s", "%-5s %s:%d " };

namespace
{
std::atomic<WallpaperLogCallback> g_log_callback { nullptr };

std::string format_message(const char* fmt, std::va_list args)
{
    std::va_list args_copy;
    va_copy(args_copy, args);
    const int length = std::vsnprintf(nullptr, 0, fmt, args_copy);
    va_end(args_copy);

    if (length < 0) return "failed to format log message";

    std::vector<char> message(static_cast<std::size_t>(length) + 1);
    std::vsnprintf(message.data(), message.size(), fmt, args);
    return std::string(message.data(), static_cast<std::size_t>(length));
}
} // namespace

void SetWallpaperLogCallback(WallpaperLogCallback callback)
{
    g_log_callback.store(callback, std::memory_order_release);
}

void WallpaperLog(int level, const char* file, int line, const char* fmt, ...) {
    std::va_list args;
    va_start(args, fmt);
    std::string message = format_message(fmt, args);
    va_end(args);

    if (auto callback = g_log_callback.load(std::memory_order_acquire)) {
        callback(level, file, line, message.c_str());
        return;
    }

    std::fprintf(stderr, level_fmt[level], level_names[level], file, line);
    std::fprintf(stderr, "%s", message.c_str());
    std::fprintf(stderr, "\n");
    std::fflush(stderr);
}

std::string logToTmpfileWithSha1(std::span<const char> in, const char* fmt, ...) {
    std::va_list          args;
    std::string           name   = utils::genSha1(in);
    std::filesystem::path fspath = std::filesystem::temp_directory_path() / name;
    std::string           path   = fspath.native();
    auto*                 file   = std::fopen(path.c_str(), "w+");
    {
        va_start(args, fmt);
        std::vfprintf(file, fmt, args);
        va_end(args);
    }
    std::fprintf(file, "\n");
    std::fclose(file);
    return path;
}
