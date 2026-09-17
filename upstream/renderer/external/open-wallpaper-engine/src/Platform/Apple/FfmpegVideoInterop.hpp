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

// Imports one decoded frame and returns an opaque owned lease, or null on
// failure. The lease retains every object the Metal texture's validity depends
// on — the Core Video texture wrapper and the pixel buffer, not just the
// MTLTexture — and must be released exactly once with
// ReleaseAppleVideoFrameLease once the GPU is finished with the frame.
//
// reusable_destination is borrowed; success always takes an independent +1
// retain, and failure never consumes the caller's retain.
void* CreateAppleVideoFrameLease(const VideoTextureFrame& frame,
                                 void* metal_device,
                                 void* reusable_destination,
                                 std::string* error);
// Borrowed id<MTLTexture> of a lease. Valid until the lease is released.
void* AppleVideoFrameLeaseTexture(void* lease);
// Moves ownership of a recyclable conversion destination out of the lease, so
// it can be handed to AppleVideoMetalTexturePool::Recycle. Returns null when
// the lease holds no poolable destination; the lease never releases a
// destination it has given away.
void* TakeAppleVideoFrameLeaseDestination(void* lease);
void ReleaseAppleVideoFrameLease(void* lease);
// Releases a retained destination texture owned outside a lease, which is what
// AppleVideoMetalTexturePool stores.
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
