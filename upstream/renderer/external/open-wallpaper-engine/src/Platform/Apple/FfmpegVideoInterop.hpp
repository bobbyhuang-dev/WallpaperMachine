#pragma once

#include "Video/VideoTextureSource.hpp"

#include <cstdint>
#include <memory>
#include <string>

struct AVBufferRef;
struct AVFrame;

namespace wallpaper::video
{

bool CreateVideoToolboxDeviceContext(AVBufferRef** hw_device_ctx, std::string* error);
bool ExtractVideoToolboxFrame(const AVFrame* frame,
                              VideoTextureFrame* out,
                              std::string* error);
bool ExtractAppleVideoFrame(const AVFrame* frame,
                            VideoTextureFrame* out,
                            std::string* error);
void ReleaseAppleVideoFrame(VideoTextureFrame* frame);
std::string DescribeAppleVideoFrame(const VideoTextureFrame& frame);

void* CreateAppleVideoMetalTexture(const VideoTextureFrame& frame, std::string* error);
// reusable_destination is borrowed; success always returns an independent +1 retain.
// Failure never consumes the caller's retain.
void* CreateAppleVideoMetalTextureForDevice(const VideoTextureFrame& frame,
                                            void* metal_device,
                                            void* reusable_destination,
                                            std::string* error);
void ReleaseAppleVideoMetalTexture(void* handle);

class AppleVideoMetalTexturePool {
public:
    explicit AppleVideoMetalTexturePool(void* metal_device);
    ~AppleVideoMetalTexturePool();
    AppleVideoMetalTexturePool(const AppleVideoMetalTexturePool&) = delete;
    AppleVideoMetalTexturePool& operator=(const AppleVideoMetalTexturePool&) = delete;
    void* Take(uint32_t width, uint32_t height);
    void Recycle(void* retained_destination) noexcept;
    void Clear() noexcept;
    uint64_t CachedTextureCount() const noexcept;
    uint64_t CachedBytes() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace wallpaper::video
