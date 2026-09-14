#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Utils/Logging.h"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <Metal/Metal.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <mutex>
#include <sstream>
#include <unordered_map>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixfmt.h>
}

namespace wallpaper::video
{
namespace
{

struct CachedMetalInteropState {
    void* command_queue { nullptr };
    void* texture_cache { nullptr };
    void* nv12_pipeline { nullptr };
};

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

void CopyPlaneRows(const uint8_t* src,
                   int            src_stride,
                   uint8_t*       dst,
                   int            dst_stride,
                   size_t         row_bytes,
                   size_t         rows)
{
    for (size_t row = 0; row < rows; ++row) {
        memcpy(dst + row * static_cast<size_t>(dst_stride),
               src + row * static_cast<size_t>(src_stride),
               row_bytes);
    }
}

CFStringRef CvMatrixAttachmentForFrame(const AVFrame* frame)
{
    if (frame == nullptr) return nullptr;

    switch (frame->colorspace) {
    case AVCOL_SPC_BT709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    case AVCOL_SPC_BT2020_CL:
    case AVCOL_SPC_BT2020_NCL: return kCVImageBufferYCbCrMatrix_ITU_R_2020;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_SMPTE240M: return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    default: return nullptr;
    }
}

OSType CvPixelFormatForSoftwareFrame(const AVFrame* frame)
{
    if (frame == nullptr) return 0;

    switch (frame->format) {
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_YUVJ420P:
    case AV_PIX_FMT_NV12:
    case AV_PIX_FMT_BGRA:
        return kCVPixelFormatType_32BGRA;
    default:
        return 0;
    }
}

struct Nv12ConversionParams {
    float y_offset;
    float y_scale;
    float r_cr;
    float g_cb;
    float g_cr;
    float b_cb;
};

struct PlaneStats {
    uint8_t min_value { 255 };
    uint8_t max_value { 0 };
    double  average { 0.0 };
    size_t  samples { 0 };
};

std::string FormatPixelFormat(OSType pixel_format)
{
    char chars[5] {
        static_cast<char>((pixel_format >> 24) & 0xff),
        static_cast<char>((pixel_format >> 16) & 0xff),
        static_cast<char>((pixel_format >> 8) & 0xff),
        static_cast<char>(pixel_format & 0xff),
        0,
    };
    bool printable = true;
    for (int i = 0; i < 4; ++i) {
        if (std::isprint(static_cast<unsigned char>(chars[i])) == 0) {
            printable = false;
            break;
        }
    }

    std::ostringstream stream;
    stream << static_cast<uint32_t>(pixel_format);
    if (printable) stream << "('" << chars << "')";
    return stream.str();
}

PlaneStats SamplePlane(
    const uint8_t* base,
    size_t width,
    size_t height,
    size_t stride,
    size_t bytes_per_pixel = 1,
    size_t channel_offset = 0)
{
    PlaneStats stats {};
    if (base == nullptr || width == 0 || height == 0 || bytes_per_pixel == 0) return stats;

    const size_t step_x = std::max<size_t>(1, width / 16);
    const size_t step_y = std::max<size_t>(1, height / 16);
    double sum = 0.0;
    for (size_t y = 0; y < height; y += step_y) {
        const uint8_t* row = base + y * stride;
        for (size_t x = 0; x < width; x += step_x) {
            const uint8_t value = row[x * bytes_per_pixel + channel_offset];
            stats.min_value = std::min(stats.min_value, value);
            stats.max_value = std::max(stats.max_value, value);
            sum += static_cast<double>(value);
            stats.samples++;
        }
    }
    if (stats.samples > 0) {
        stats.average = sum / static_cast<double>(stats.samples);
    } else {
        stats.min_value = 0;
    }
    return stats;
}

void AppendPlaneStats(std::ostringstream& stream, const char* name, const PlaneStats& stats)
{
    stream << ' ' << name << "{min=" << static_cast<int>(stats.min_value)
           << " max=" << static_cast<int>(stats.max_value)
           << " avg=" << stats.average
           << " samples=" << stats.samples
           << '}';
}

Nv12ConversionParams ConversionParamsForFrame(const AVFrame* frame)
{
    Nv12ConversionParams params {
        .y_offset = frame != nullptr && frame->color_range != AVCOL_RANGE_JPEG ? (16.0f / 255.0f) : 0.0f,
        .y_scale = frame != nullptr && frame->color_range != AVCOL_RANGE_JPEG ? (255.0f / 219.0f) : 1.0f,
        .r_cr = 1.402f,
        .g_cb = -0.344136f,
        .g_cr = -0.714136f,
        .b_cb = 1.772f,
    };

    if (frame == nullptr) {
        return params;
    }

    switch (frame->colorspace) {
    case AVCOL_SPC_BT709:
        params.r_cr = 1.5748f;
        params.g_cb = -0.187324f;
        params.g_cr = -0.468124f;
        params.b_cb = 1.8556f;
        break;
    case AVCOL_SPC_BT2020_CL:
    case AVCOL_SPC_BT2020_NCL:
        params.r_cr = 1.4746f;
        params.g_cb = -0.164553f;
        params.g_cr = -0.571353f;
        params.b_cb = 1.8814f;
        break;
    default:
        break;
    }

    return params;
}

bool CopySoftwareFrameToPixelBuffer(const AVFrame* frame,
                                    CVPixelBufferRef pixel_buffer,
                                    std::string* error)
{
    if (frame == nullptr || pixel_buffer == nullptr) {
        return SetError(error, "software video copy received a null frame or pixel buffer");
    }

    const CVReturn lock_result = CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    if (lock_result != kCVReturnSuccess) {
        return SetError(error, "failed to lock software video pixel buffer");
    }

    const auto unlock = [&]() {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    };

    const int width = frame->width;
    const int height = frame->height;
    if (width <= 0 || height <= 0) {
        unlock();
        return SetError(error, "software video frame returned an invalid size");
    }

    switch (frame->format) {
    case AV_PIX_FMT_BGRA: {
        auto* destination =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        if (destination == nullptr) {
            unlock();
            return SetError(error, "BGRA video pixel buffer has no base address");
        }
        const int destination_stride =
            static_cast<int>(CVPixelBufferGetBytesPerRow(pixel_buffer));
        CopyPlaneRows(frame->data[0],
                      frame->linesize[0],
                      destination,
                      destination_stride,
                      static_cast<size_t>(width) * 4u,
                      static_cast<size_t>(height));
        unlock();
        return true;
    }
    case AV_PIX_FMT_NV12: {
        auto* destination =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        if (destination == nullptr) {
            unlock();
            return SetError(error, "BGRA video pixel buffer has no base address");
        }
        const int destination_stride =
            static_cast<int>(CVPixelBufferGetBytesPerRow(pixel_buffer));
        const auto params = ConversionParamsForFrame(frame);
        for (int y = 0; y < height; ++y) {
            const uint8_t* src_y = frame->data[0] + y * frame->linesize[0];
            const uint8_t* src_uv = frame->data[1] + (y / 2) * frame->linesize[1];
            uint8_t* dst = destination + y * destination_stride;
            for (int x = 0; x < width; ++x) {
                const float luma = std::clamp((static_cast<float>(src_y[x]) / 255.0f - params.y_offset) * params.y_scale, 0.0f, 1.0f);
                const float cb = static_cast<float>(src_uv[(x / 2) * 2]) / 255.0f - 0.5f;
                const float cr = static_cast<float>(src_uv[(x / 2) * 2 + 1]) / 255.0f - 0.5f;
                const float r = std::clamp(luma + params.r_cr * cr, 0.0f, 1.0f);
                const float g = std::clamp(luma + params.g_cb * cb + params.g_cr * cr, 0.0f, 1.0f);
                const float b = std::clamp(luma + params.b_cb * cb, 0.0f, 1.0f);
                dst[x * 4] = static_cast<uint8_t>(std::lround(b * 255.0f));
                dst[x * 4 + 1] = static_cast<uint8_t>(std::lround(g * 255.0f));
                dst[x * 4 + 2] = static_cast<uint8_t>(std::lround(r * 255.0f));
                dst[x * 4 + 3] = 255;
            }
        }
        unlock();
        return true;
    }
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_YUVJ420P: {
        auto* destination =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        if (destination == nullptr) {
            unlock();
            return SetError(error, "BGRA video pixel buffer has no base address");
        }
        const int destination_stride =
            static_cast<int>(CVPixelBufferGetBytesPerRow(pixel_buffer));
        const auto params = ConversionParamsForFrame(frame);
        for (int y = 0; y < height; ++y) {
            const uint8_t* src_y = frame->data[0] + y * frame->linesize[0];
            const uint8_t* src_u = frame->data[1] + (y / 2) * frame->linesize[1];
            const uint8_t* src_v = frame->data[2] + (y / 2) * frame->linesize[2];
            uint8_t* dst = destination + y * destination_stride;
            for (int x = 0; x < width; ++x) {
                const float luma = std::clamp((static_cast<float>(src_y[x]) / 255.0f - params.y_offset) * params.y_scale, 0.0f, 1.0f);
                const float cb = static_cast<float>(src_u[x / 2]) / 255.0f - 0.5f;
                const float cr = static_cast<float>(src_v[x / 2]) / 255.0f - 0.5f;
                const float r = std::clamp(luma + params.r_cr * cr, 0.0f, 1.0f);
                const float g = std::clamp(luma + params.g_cb * cb + params.g_cr * cr, 0.0f, 1.0f);
                const float b = std::clamp(luma + params.b_cb * cb, 0.0f, 1.0f);
                dst[x * 4] = static_cast<uint8_t>(std::lround(b * 255.0f));
                dst[x * 4 + 1] = static_cast<uint8_t>(std::lround(g * 255.0f));
                dst[x * 4 + 2] = static_cast<uint8_t>(std::lround(r * 255.0f));
                dst[x * 4 + 3] = 255;
            }
        }
        unlock();
        return true;
    }
    default:
        unlock();
        return SetError(error, "software video frame format is not supported");
    }
}

bool ExtractSoftwareVideoFrame(const AVFrame* frame,
                               VideoTextureFrame* out,
                               std::string* error)
{
    if (frame == nullptr) return SetError(error, "decoded software FFmpeg frame must not be null");
    if (out == nullptr) return SetError(error, "software video texture frame output must not be null");

    const OSType pixel_format = CvPixelFormatForSoftwareFrame(frame);
    if (pixel_format == 0) {
        return SetError(error, "software FFmpeg frame format is not supported on Apple video path");
    }

    CVPixelBufferRef pixel_buffer = nullptr;
    const CVReturn create_result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        static_cast<size_t>(frame->width),
        static_cast<size_t>(frame->height),
        pixel_format,
        nullptr,
        &pixel_buffer);
    if (create_result != kCVReturnSuccess || pixel_buffer == nullptr) {
        return SetError(
            error,
            "failed to create software video pixel buffer: " + std::to_string(create_result));
    }

    if (!CopySoftwareFrameToPixelBuffer(frame, pixel_buffer, error)) {
        CFRelease(pixel_buffer);
        return false;
    }

    if (const auto matrix = CvMatrixAttachmentForFrame(frame); matrix != nullptr) {
        CVBufferSetAttachment(pixel_buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    }

    IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
    CFRetain(pixel_buffer);
    if (io_surface != nullptr) {
        CFRetain(io_surface);
    }
    out->width = static_cast<uint32_t>(CVPixelBufferGetWidth(pixel_buffer));
    out->height = static_cast<uint32_t>(CVPixelBufferGetHeight(pixel_buffer));
    out->pixel_buffer = pixel_buffer;
    out->io_surface = io_surface;
    out->pixel_format = static_cast<uint32_t>(CVPixelBufferGetPixelFormatType(pixel_buffer));
    out->plane_count = CVPixelBufferIsPlanar(pixel_buffer)
        ? static_cast<uint32_t>(CVPixelBufferGetPlaneCount(pixel_buffer))
        : 1u;
    CFRelease(pixel_buffer);
    return true;
}

static constexpr const char* kNv12ConversionShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct Nv12ConversionParams {
    float y_offset;
    float y_scale;
    float r_cr;
    float g_cb;
    float g_cr;
    float b_cb;
};

kernel void nv12_to_bgra(texture2d<float, access::sample> y_texture [[texture(0)]],
                         texture2d<float, access::sample> uv_texture [[texture(1)]],
                         texture2d<half, access::write> output_texture [[texture(2)]],
                         constant Nv12ConversionParams& params [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output_texture.get_width() || gid.y >= output_texture.get_height()) {
        return;
    }

    constexpr sampler sample_state(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 uv = (float2(gid) + 0.5f) /
        float2(output_texture.get_width(), output_texture.get_height());
    const float  y = y_texture.sample(sample_state, uv).r;
    const float2 cbcr = uv_texture.sample(sample_state, uv).rg - float2(0.5f, 0.5f);
    const float  luma = clamp((y - params.y_offset) * params.y_scale, 0.0f, 1.0f);

    const float r = saturate(luma + params.r_cr * cbcr.y);
    const float g = saturate(luma + params.g_cb * cbcr.x + params.g_cr * cbcr.y);
    const float b = saturate(luma + params.b_cb * cbcr.x);
    output_texture.write(half4(half(r), half(g), half(b), half(1.0f)), gid);
}
)";

CachedMetalInteropState* GetCachedMetalInteropState(id<MTLDevice> device, std::string* error)
{
    static std::mutex                                               mutex;
    static std::unordered_map<void*, CachedMetalInteropState>       states;
    const void* const key = (__bridge void*)device;
    std::lock_guard lock(mutex);
    auto [iterator, inserted] = states.try_emplace(const_cast<void*>(key));
    if (inserted) {
        iterator->second.command_queue = (__bridge_retained void*)[device newCommandQueue];
        CVMetalTextureCacheRef texture_cache = nullptr;
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &texture_cache) ==
            kCVReturnSuccess) {
            iterator->second.texture_cache = texture_cache;
        }

        NSError* library_error = nil;
        NSString* source =
            [NSString stringWithUTF8String:kNv12ConversionShaderSource];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&library_error];
        if (library != nil) {
            id<MTLFunction> function = [library newFunctionWithName:@"nv12_to_bgra"];
            if (function != nil) {
                NSError* pipeline_error = nil;
                id<MTLComputePipelineState> pipeline =
                    [device newComputePipelineStateWithFunction:function error:&pipeline_error];
                if (pipeline != nil) {
                    iterator->second.nv12_pipeline = (__bridge_retained void*)pipeline;
                } else if (error != nullptr && pipeline_error != nil && error->empty()) {
                    *error = std::string([[pipeline_error localizedDescription] UTF8String]);
                }
            } else if (error != nullptr && error->empty()) {
                *error = "failed to load nv12_to_bgra Metal function";
            }
        } else if (error != nullptr && library_error != nil && error->empty()) {
            *error = std::string([[library_error localizedDescription] UTF8String]);
        }
    }
    return &iterator->second;
}

id<MTLCommandQueue> GetCommandQueueForDevice(id<MTLDevice> device, std::string* error)
{
    CachedMetalInteropState* state = GetCachedMetalInteropState(device, error);
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)state->command_queue;
    if (queue == nil) {
        SetError(error, "failed to create Metal command queue for video texture conversion");
    }
    return queue;
}

CVMetalTextureCacheRef GetTextureCacheForDevice(id<MTLDevice> device, std::string* error)
{
    CachedMetalInteropState* state = GetCachedMetalInteropState(device, error);
    auto texture_cache = reinterpret_cast<CVMetalTextureCacheRef>(state->texture_cache);
    if (texture_cache == nullptr) {
        SetError(error, "failed to create CVMetalTextureCache for video texture conversion");
    }
    return texture_cache;
}

id<MTLComputePipelineState> GetNv12PipelineForDevice(id<MTLDevice> device, std::string* error)
{
    CachedMetalInteropState* state = GetCachedMetalInteropState(device, error);
    id<MTLComputePipelineState> pipeline = (__bridge id<MTLComputePipelineState>)state->nv12_pipeline;
    if (pipeline == nil) {
        if (error != nullptr && error->empty()) {
            SetError(error, "failed to create Metal compute pipeline for NV12 video conversion");
        }
    }
    return pipeline;
}

id<MTLTexture> CreateDirectMetalTexture(id<MTLDevice> device,
                                        IOSurfaceRef  surface,
                                        uint32_t      width,
                                        uint32_t      height,
                                        std::string*  error)
{
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.resourceOptions = MTLResourceStorageModeShared;

    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
    if (texture == nil) {
        SetError(error, "failed to create Metal texture view for BGRA IOSurface-backed video frame");
    }
    return texture;
}

id<MTLTexture> CreatePixelBufferBackedMetalTexture(id<MTLDevice> device,
                                                   CVPixelBufferRef pixel_buffer,
                                                   MTLPixelFormat pixel_format,
                                                   uint32_t width,
                                                   uint32_t height,
                                                   std::string* error)
{
    CVMetalTextureCacheRef texture_cache = GetTextureCacheForDevice(device, error);
    if (texture_cache == nullptr) return nil;

    CVMetalTextureRef texture_ref = nullptr;
    const CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        texture_cache,
        pixel_buffer,
        nullptr,
        pixel_format,
        width,
        height,
        0,
        &texture_ref);
    if (result != kCVReturnSuccess || texture_ref == nullptr) {
        return SetError(error, "failed to create Metal texture from BGRA pixel buffer"), nil;
    }

    id<MTLTexture> texture = CVMetalTextureGetTexture(texture_ref);
    if (texture == nil) {
        CFRelease(texture_ref);
        return SetError(error, "CVMetalTextureCache returned a null BGRA texture"), nil;
    }

    CFRelease(texture_ref);
    return texture;
}

id<MTLTexture> CreateConvertedMetalTexture(id<MTLDevice>    device,
                                           CVPixelBufferRef pixel_buffer,
                                           OSType           pixel_format,
                                           uint32_t         width,
                                           uint32_t         height,
                                           std::string*     error)
{
    CVMetalTextureCacheRef texture_cache = GetTextureCacheForDevice(device, error);
    if (texture_cache == nullptr) return nil;

    id<MTLCommandQueue> command_queue = GetCommandQueueForDevice(device, error);
    if (command_queue == nil) return nil;

    id<MTLComputePipelineState> pipeline = GetNv12PipelineForDevice(device, error);
    if (pipeline == nil) return nil;

    CVMetalTextureRef y_plane_ref = nullptr;
    CVMetalTextureRef uv_plane_ref = nullptr;
    const CVReturn y_result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        texture_cache,
        pixel_buffer,
        nullptr,
        MTLPixelFormatR8Unorm,
        width,
        height,
        0,
        &y_plane_ref);
    if (y_result != kCVReturnSuccess || y_plane_ref == nullptr) {
        return SetError(error, "failed to create Metal texture for NV12 luma plane"), nil;
    }

    const CVReturn uv_result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        texture_cache,
        pixel_buffer,
        nullptr,
        MTLPixelFormatRG8Unorm,
        width / 2u,
        height / 2u,
        1,
        &uv_plane_ref);
    if (uv_result != kCVReturnSuccess || uv_plane_ref == nullptr) {
        CFRelease(y_plane_ref);
        return SetError(error, "failed to create Metal texture for NV12 chroma plane"), nil;
    }

    id<MTLTexture> y_texture = CVMetalTextureGetTexture(y_plane_ref);
    id<MTLTexture> uv_texture = CVMetalTextureGetTexture(uv_plane_ref);
    if (y_texture == nil || uv_texture == nil) {
        CFRelease(y_plane_ref);
        CFRelease(uv_plane_ref);
        return SetError(error, "CVMetalTextureCache returned null plane textures"), nil;
    }

    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.resourceOptions = MTLResourceStorageModeShared;

    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        CFRelease(y_plane_ref);
        CFRelease(uv_plane_ref);
        SetError(error, "failed to allocate destination Metal texture for video texture conversion");
        return nil;
    }

    id<MTLCommandBuffer> command_buffer = [command_queue commandBuffer];
    if (command_buffer == nil) {
        CFRelease(y_plane_ref);
        CFRelease(uv_plane_ref);
        SetError(error, "failed to allocate Metal command buffer for video texture conversion");
        return nil;
    }

    id<MTLComputeCommandEncoder> encoder = [command_buffer computeCommandEncoder];
    if (encoder == nil) {
        CFRelease(y_plane_ref);
        CFRelease(uv_plane_ref);
        SetError(error, "failed to allocate Metal compute encoder for video texture conversion");
        return nil;
    }

    Nv12ConversionParams params {
        .y_offset = pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? (16.0f / 255.0f) : 0.0f,
        .y_scale = pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? (255.0f / 219.0f) : 1.0f,
        .r_cr = 1.402f,
        .g_cb = -0.344136f,
        .g_cr = -0.714136f,
        .b_cb = 1.772f,
    };
    CFTypeRef matrix_attachment =
        CVBufferCopyAttachment(pixel_buffer, kCVImageBufferYCbCrMatrixKey, nullptr);
    if (matrix_attachment != nullptr && CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
        params.r_cr = 1.5748f;
        params.g_cb = -0.187324f;
        params.g_cr = -0.468124f;
        params.b_cb = 1.8556f;
    } else if (matrix_attachment != nullptr && CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        params.r_cr = 1.4746f;
        params.g_cb = -0.164553f;
        params.g_cr = -0.571353f;
        params.b_cb = 1.8814f;
    }
    if (matrix_attachment != nullptr) {
        CFRelease(matrix_attachment);
    }

    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:y_texture atIndex:0];
    [encoder setTexture:uv_texture atIndex:1];
    [encoder setTexture:texture atIndex:2];
    [encoder setBytes:&params length:sizeof(params) atIndex:0];

    const NSUInteger thread_width = std::min<NSUInteger>(16u, pipeline.threadExecutionWidth);
    const NSUInteger thread_height = std::max<NSUInteger>(1u, pipeline.maxTotalThreadsPerThreadgroup / thread_width);
    const MTLSize threads_per_group = MTLSizeMake(thread_width, std::min<NSUInteger>(16u, thread_height), 1u);
    const MTLSize threads_per_grid = MTLSizeMake(width, height, 1u);
    [encoder dispatchThreads:threads_per_grid threadsPerThreadgroup:threads_per_group];
    [encoder endEncoding];

    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    CFRelease(y_plane_ref);
    CFRelease(uv_plane_ref);
    if (command_buffer.status == MTLCommandBufferStatusError) {
        SetError(
            error,
            command_buffer.error != nil
                ? std::string([[command_buffer.error localizedDescription] UTF8String])
                : "Metal command buffer failed while converting VideoToolbox frame");
        return nil;
    }

    return texture;
}

} // namespace

bool CreateVideoToolboxDeviceContext(AVBufferRef** hw_device_ctx, std::string* error)
{
    if (hw_device_ctx == nullptr) {
        return SetError(error, "VideoToolbox hardware device output must not be null");
    }

    AVBufferRef* device_ctx = nullptr;
    const int result = av_hwdevice_ctx_create(
        &device_ctx,
        AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
        nullptr,
        nullptr,
        0);
    if (result < 0 || device_ctx == nullptr) {
        return SetError(error, "failed to create FFmpeg VideoToolbox hardware device context");
    }

    *hw_device_ctx = device_ctx;
    return true;
}

bool ExtractVideoToolboxFrame(const AVFrame* frame,
                              VideoTextureFrame* out,
                              std::string* error)
{
    if (frame == nullptr) return SetError(error, "decoded FFmpeg frame must not be null");
    if (out == nullptr) return SetError(error, "video texture frame output must not be null");
    if (frame->format != AV_PIX_FMT_VIDEOTOOLBOX) {
        return SetError(error, "decoded FFmpeg frame is not backed by VideoToolbox");
    }

    CVPixelBufferRef pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
    if (pixel_buffer == nullptr) {
        return SetError(error, "VideoToolbox frame does not carry a pixel buffer");
    }

    CFRetain(pixel_buffer);
    IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
    if (io_surface != nullptr) {
        CFRetain(io_surface);
    }
    out->width = static_cast<uint32_t>(CVPixelBufferGetWidth(pixel_buffer));
    out->height = static_cast<uint32_t>(CVPixelBufferGetHeight(pixel_buffer));
    out->pixel_buffer = pixel_buffer;
    out->io_surface = io_surface;
    out->pixel_format = static_cast<uint32_t>(CVPixelBufferGetPixelFormatType(pixel_buffer));
    out->plane_count = CVPixelBufferIsPlanar(pixel_buffer)
        ? static_cast<uint32_t>(CVPixelBufferGetPlaneCount(pixel_buffer))
        : 1u;
    return true;
}

bool ExtractAppleVideoFrame(const AVFrame* frame,
                            VideoTextureFrame* out,
                            std::string* error)
{
    if (frame == nullptr) return SetError(error, "decoded FFmpeg frame must not be null");
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        return ExtractVideoToolboxFrame(frame, out, error);
    }
    return ExtractSoftwareVideoFrame(frame, out, error);
}

void ReleaseAppleVideoFrame(VideoTextureFrame* frame)
{
    if (frame == nullptr) return;
    if (frame->io_surface != nullptr) {
        CFRelease(reinterpret_cast<IOSurfaceRef>(frame->io_surface));
        frame->io_surface = nullptr;
    }
    if (frame->pixel_buffer != nullptr) {
        CFRelease(reinterpret_cast<CVPixelBufferRef>(frame->pixel_buffer));
        frame->pixel_buffer = nullptr;
    }
    frame->pixel_format = 0;
    frame->plane_count = 0;
}

std::string DescribeAppleVideoFrame(const VideoTextureFrame& frame)
{
    std::ostringstream stream;
    const auto pixel_format = static_cast<OSType>(frame.pixel_format);
    stream << "fmt=" << FormatPixelFormat(pixel_format)
           << " size=" << frame.width << 'x' << frame.height
           << " planes=" << frame.plane_count;

    if (frame.pixel_buffer == nullptr) {
        stream << " pixel_buffer=null io_surface=" << (frame.io_surface != nullptr ? "yes" : "no");
        return stream.str();
    }

    auto pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer);
    const CVReturn lock_result = CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    if (lock_result != kCVReturnSuccess) {
        stream << " lock_failed=" << lock_result;
        return stream.str();
    }

    const auto unlock = [&]() {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    };

    if (CVPixelBufferIsPlanar(pixel_buffer)) {
        const size_t plane_count = CVPixelBufferGetPlaneCount(pixel_buffer);
        const size_t reported_planes = std::min<size_t>(plane_count, 3);
        for (size_t plane = 0; plane < reported_planes; ++plane) {
            const auto* base = static_cast<const uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
            const size_t width = CVPixelBufferGetWidthOfPlane(pixel_buffer, plane);
            const size_t height = CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
            const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane);
            const auto stats = SamplePlane(base, width, height, stride);
            std::ostringstream name;
            name << 'p' << plane;
            AppendPlaneStats(stream, name.str().c_str(), stats);
        }
    } else {
        const auto* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
        const size_t width = CVPixelBufferGetWidth(pixel_buffer);
        const size_t height = CVPixelBufferGetHeight(pixel_buffer);
        const size_t stride = CVPixelBufferGetBytesPerRow(pixel_buffer);
        if (pixel_format == kCVPixelFormatType_32BGRA) {
            AppendPlaneStats(stream, "b", SamplePlane(base, width, height, stride, 4, 0));
            AppendPlaneStats(stream, "g", SamplePlane(base, width, height, stride, 4, 1));
            AppendPlaneStats(stream, "r", SamplePlane(base, width, height, stride, 4, 2));
        } else {
            AppendPlaneStats(stream, "packed", SamplePlane(base, width, height, stride));
        }
    }

    unlock();
    return stream.str();
}

void* CreateAppleVideoMetalTextureForDevice(const VideoTextureFrame& frame,
                                            void* metal_device,
                                            std::string* error)
{
    if (!frame.valid()) {
        return SetError(error, "video frame metadata is incomplete"), nullptr;
    }

    @autoreleasepool {
        id<MTLDevice> device = metal_device != nullptr
            ? (__bridge id<MTLDevice>)metal_device
            : MTLCreateSystemDefaultDevice();
        if (device == nil) {
            SetError(error, "failed to create Metal device for video texture import");
            return nullptr;
        }

        id<MTLTexture> texture = nil;
        const OSType pixel_format = static_cast<OSType>(frame.pixel_format);
        if (pixel_format == kCVPixelFormatType_32BGRA && frame.io_surface != nullptr) {
            texture = CreateDirectMetalTexture(
                device,
                reinterpret_cast<IOSurfaceRef>(frame.io_surface),
                frame.width,
                frame.height,
                error);
        } else if (pixel_format == kCVPixelFormatType_32BGRA && frame.pixel_buffer != nullptr) {
            texture = CreatePixelBufferBackedMetalTexture(
                device,
                reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer),
                MTLPixelFormatBGRA8Unorm,
                frame.width,
                frame.height,
                error);
        } else if ((pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                    pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) &&
                   frame.pixel_buffer != nullptr) {
            texture = CreateConvertedMetalTexture(
                device,
                reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer),
                pixel_format,
                frame.width,
                frame.height,
                error);
        } else if (frame.io_surface != nullptr && frame.pixel_buffer == nullptr) {
            texture = CreateDirectMetalTexture(
                device,
                reinterpret_cast<IOSurfaceRef>(frame.io_surface),
                frame.width,
                frame.height,
                error);
        }
        if (texture == nil) {
            if (error != nullptr && error->empty()) {
                SetError(error, "failed to create Metal texture for imported video frame");
            }
            return nullptr;
        }

        return (__bridge_retained void*)texture;
    }
}

void* CreateAppleVideoMetalTexture(const VideoTextureFrame& frame, std::string* error)
{
    return CreateAppleVideoMetalTextureForDevice(frame, nullptr, error);
}

void ReleaseAppleVideoMetalTexture(void* handle)
{
    if (handle == nullptr) return;

    @autoreleasepool {
        (void)CFBridgingRelease(handle);
    }
}

} // namespace wallpaper::video
