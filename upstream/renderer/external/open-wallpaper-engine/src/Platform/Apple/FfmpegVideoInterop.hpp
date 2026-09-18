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
// retain, and failure never consumes the caller's retain. When it is given,
// destination_allocation_failed reports whether the failure was the
// conversion destination's own allocation — the one failure that a retry at
// the same size cannot fix.
void* CreateAppleVideoFrameLease(const VideoTextureFrame& frame,
                                 void* metal_device,
                                 void* reusable_destination,
                                 std::string* error,
                                 bool* destination_allocation_failed = nullptr);
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

/// What one conversion pool has done. Counted per pool, which is per texture
/// cache, which is per renderer instance.
struct AppleVideoConversionPoolStats {
    uint64_t cached_texture_count { 0 };
    uint64_t cached_bytes { 0 };
    uint64_t peak_cached_bytes { 0 };
    uint64_t hits { 0 };
    uint64_t misses { 0 };
    uint64_t recycles { 0 };
    uint64_t evictions { 0 };
    uint64_t refusals { 0 };
};

/// Reuse pool for the BGRA8 textures the NV12 conversion writes into.
///
/// The pool executes; `VideoConversionBudget` decides. Reuse is keyed on the
/// decoded frame's width, height and the destination pixel format, so a
/// differently shaped texture is never handed out for an incompatible
/// request, and the ceiling is expressed in the bytes Metal reports it
/// allocated rather than in a texture count.
class AppleVideoMetalTexturePool {
public:
    explicit AppleVideoMetalTexturePool(void* metal_device);
    ~AppleVideoMetalTexturePool();
    AppleVideoMetalTexturePool(const AppleVideoMetalTexturePool&) = delete;
    AppleVideoMetalTexturePool& operator=(const AppleVideoMetalTexturePool&) = delete;
    // Borrows a destination for a decoded frame of exactly this size, or
    // returns null. width and height are the decoded frame's; a surface or
    // display resolution is a different quantity and must never be passed
    // here. The returned retain belongs to the caller, and the loan stays open
    // until Recycle or EndLoan, so one texture is never lent to two frames.
    void* Take(uint32_t width, uint32_t height);
    // Ends a loan whose import never used the destination, releasing it.
    void EndLoan(void* retained_destination) noexcept;
    // Offers a destination back now that the GPU has finished with it. The
    // renderer calls this from the frame lease's deleter, which runs after the
    // imported frame's last holder drops it — after the draw fence that
    // sampled the frame signalled, and after the Vulkan image aliasing the
    // texture was destroyed.
    void Recycle(void* retained_destination) noexcept;
    // Drops cached destinations of every size other than this one, so a
    // resolution change stops holding shapes nothing requests any more.
    void RetainOnly(uint32_t width, uint32_t height) noexcept;
    // A fresh destination of this size could not be allocated. The pool gives
    // back what it holds and stops caching that size and larger, so an
    // unsatisfiable allocation is attempted once instead of once per frame.
    void ReportAllocationFailure(uint32_t width, uint32_t height) noexcept;
    void Clear() noexcept;
    [[nodiscard]] AppleVideoConversionPoolStats Stats() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace wallpaper::video
