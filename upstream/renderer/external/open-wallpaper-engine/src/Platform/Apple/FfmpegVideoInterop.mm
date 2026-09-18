#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Video/VideoColorConversion.hpp"
#include "Video/VideoConversionBudget.hpp"
#include "Utils/Logging.h"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <mutex>
#include <sstream>
#include <unordered_map>
#include <vector>

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

/// Reads the colorimetry a decoded frame declares. Unknown metadata is
/// inferred from the resolution and reported, rather than silently treated as
/// BT.601 for everything.
YuvColorDescription ColorDescriptionForFrame(const AVFrame* frame)
{
    YuvColorDescription description {};
    if (frame == nullptr) return description;

    description.range =
        frame->color_range == AVCOL_RANGE_JPEG ? YuvRange::Full : YuvRange::Limited;
    switch (frame->colorspace) {
    case AVCOL_SPC_BT709:
        description.matrix = YuvMatrix::Bt709;
        break;
    case AVCOL_SPC_BT2020_NCL:
        description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
        break;
    case AVCOL_SPC_BT2020_CL:
        // Constant-luminance BT.2020 needs a different transform. Report the
        // substitution instead of claiming support for it.
        description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
        description.matrix_inferred = true;
        break;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_SMPTE240M:
        description.matrix = YuvMatrix::Bt601;
        break;
    default:
        description.matrix = InferYuvMatrix(static_cast<uint32_t>(std::max(0, frame->width)),
                                            static_cast<uint32_t>(std::max(0, frame->height)));
        description.matrix_inferred = true;
        break;
    }
    return description;
}

/// Colorimetry of a Core Video pixel buffer, which is what the hardware
/// decoder hands over. The pixel format decides the range; the attachment, when
/// present, decides the matrix.
YuvColorDescription ColorDescriptionForPixelBuffer(CVPixelBufferRef pixel_buffer,
                                                   OSType pixel_format,
                                                   uint32_t width,
                                                   uint32_t height)
{
    YuvColorDescription description {};
    description.range = pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ? YuvRange::Full
        : YuvRange::Limited;

    CFTypeRef matrix_attachment =
        CVBufferCopyAttachment(pixel_buffer, kCVImageBufferYCbCrMatrixKey, nullptr);
    if (matrix_attachment == nullptr) {
        description.matrix = InferYuvMatrix(width, height);
        description.matrix_inferred = true;
        return description;
    }
    if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
        description.matrix = YuvMatrix::Bt709;
    } else if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
    } else if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) ||
               CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) {
        description.matrix = YuvMatrix::Bt601;
    } else {
        description.matrix = InferYuvMatrix(width, height);
        description.matrix_inferred = true;
    }
    CFRelease(matrix_attachment);
    return description;
}

/// One line per distinct colorimetry so an inferred matrix is visible in the
/// log without printing anything per frame.
void ReportInferredColor(const YuvColorDescription& description)
{
    if (!description.matrix_inferred) return;
    static std::mutex mutex;
    static std::unordered_map<uint32_t, bool> reported;
    const uint32_t key = (static_cast<uint32_t>(description.matrix) << 8) |
        static_cast<uint32_t>(description.range);
    std::lock_guard lock(mutex);
    if (!reported.try_emplace(key, true).second) return;
    LOG_INFO("video color metadata missing or unsupported; using %s %s range",
             YuvMatrixName(description.matrix),
             YuvRangeName(description.range));
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
        const auto description = ColorDescriptionForFrame(frame);
        ReportInferredColor(description);
        const auto params = MakeYuvColorParams(description);
        for (int y = 0; y < height; ++y) {
            const uint8_t* src_y = frame->data[0] + y * frame->linesize[0];
            const uint8_t* src_uv = frame->data[1] + (y / 2) * frame->linesize[1];
            uint8_t* dst = destination + y * destination_stride;
            for (int x = 0; x < width; ++x) {
                const Rgb8 rgb = ConvertYuvCodeToRgb8(
                    params, src_y[x], src_uv[(x / 2) * 2], src_uv[(x / 2) * 2 + 1]);
                dst[x * 4] = rgb.blue;
                dst[x * 4 + 1] = rgb.green;
                dst[x * 4 + 2] = rgb.red;
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
        const auto description = ColorDescriptionForFrame(frame);
        ReportInferredColor(description);
        const auto params = MakeYuvColorParams(description);
        for (int y = 0; y < height; ++y) {
            const uint8_t* src_y = frame->data[0] + y * frame->linesize[0];
            const uint8_t* src_u = frame->data[1] + (y / 2) * frame->linesize[1];
            const uint8_t* src_v = frame->data[2] + (y / 2) * frame->linesize[2];
            uint8_t* dst = destination + y * destination_stride;
            for (int x = 0; x < width; ++x) {
                const Rgb8 rgb =
                    ConvertYuvCodeToRgb8(params, src_y[x], src_u[x / 2], src_v[x / 2]);
                dst[x * 4] = rgb.blue;
                dst[x * 4 + 1] = rgb.green;
                dst[x * 4 + 2] = rgb.red;
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

// Field order and meaning are fixed by wallpaper::video::YuvColorParams, so the
// kernel and the CPU reference conversion cannot disagree about range or matrix.
struct YuvColorParams {
    float y_offset;
    float y_scale;
    float chroma_offset;
    float chroma_scale;
    float r_cr;
    float g_cb;
    float g_cr;
    float b_cb;
};

kernel void nv12_to_bgra(texture2d<float, access::sample> y_texture [[texture(0)]],
                         texture2d<float, access::sample> uv_texture [[texture(1)]],
                         texture2d<half, access::write> output_texture [[texture(2)]],
                         constant YuvColorParams& params [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output_texture.get_width() || gid.y >= output_texture.get_height()) {
        return;
    }

    constexpr sampler sample_state(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 uv = (float2(gid) + 0.5f) /
        float2(output_texture.get_width(), output_texture.get_height());
    const float  y = y_texture.sample(sample_state, uv).r;
    // Limited-range chroma spans 224 code values around the midpoint, so the
    // offset and the scale are both part of the contract.
    const float2 cbcr = (uv_texture.sample(sample_state, uv).rg - params.chroma_offset) *
        params.chroma_scale;
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

/// On success the caller owns `*out_wrapper` and must keep it alive for as long
/// as the returned texture can be used by the GPU: Core Video documents the
/// wrapper, not the vended MTLTexture, as the object whose lifetime governs the
/// texture's validity.
id<MTLTexture> CreatePixelBufferBackedMetalTexture(id<MTLDevice> device,
                                                   CVPixelBufferRef pixel_buffer,
                                                   MTLPixelFormat pixel_format,
                                                   uint32_t width,
                                                   uint32_t height,
                                                   CVMetalTextureRef* out_wrapper,
                                                   std::string* error)
{
    if (out_wrapper == nullptr) {
        return SetError(error, "Core Video texture wrapper output must not be null"), nil;
    }
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

    *out_wrapper = texture_ref;
    return texture;
}

/// Pixel format the NV12 conversion kernel writes. It is part of the reuse key
/// because a destination is only interchangeable with one the importer
/// reinterprets the same way.
constexpr MTLPixelFormat kConversionDestinationPixelFormat = MTLPixelFormatBGRA8Unorm;

/// Bytes a destination of this shape would cost. Only used to record a
/// failure, where there is no texture left to ask for its allocated size.
uint64_t NominalConversionDestinationBytes(uint32_t width, uint32_t height)
{
    return static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4u;
}

/// Whether committing `bytes` more would push this device past the working set
/// size it recommends. This is the memory-pressure signal Metal answers
/// synchronously, so reading it needs no notification source and no thread.
bool DeviceIsUnderMemoryPressure(id<MTLDevice> device, uint64_t bytes)
{
    const uint64_t recommended = device.recommendedMaxWorkingSetSize;
    if (recommended == 0) return false;
    return static_cast<uint64_t>(device.currentAllocatedSize) + bytes > recommended;
}

bool CompatibleConvertedDestination(id<MTLTexture> texture, id<MTLDevice> device,
                                    uint32_t width, uint32_t height)
{
    const MTLTextureUsage required_usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return texture != nil && texture.device == device &&
        texture.textureType == MTLTextureType2D &&
        texture.width == width && texture.height == height && texture.depth == 1 &&
        texture.pixelFormat == kConversionDestinationPixelFormat &&
        texture.storageMode == MTLStorageModeShared &&
        texture.mipmapLevelCount == 1 && texture.sampleCount == 1 && texture.arrayLength == 1 &&
        (texture.usage & required_usage) == required_usage;
}

id<MTLTexture> CreateConvertedMetalTexture(id<MTLDevice>    device,
                                           CVPixelBufferRef pixel_buffer,
                                           OSType           pixel_format,
                                           uint32_t         width,
                                           uint32_t         height,
                                           id<MTLTexture>   reusable_destination,
                                           bool*            destination_allocation_failed,
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

    id<MTLTexture> texture = reusable_destination;
    if (texture == nil) {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kConversionDestinationPixelFormat
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.resourceOptions = MTLResourceStorageModeShared;
        texture = [device newTextureWithDescriptor:descriptor];
        if (texture == nil && destination_allocation_failed != nullptr) {
            *destination_allocation_failed = true;
        }
    }
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

    const YuvColorDescription description =
        ColorDescriptionForPixelBuffer(pixel_buffer, pixel_format, width, height);
    ReportInferredColor(description);
    const YuvColorParams params = MakeYuvColorParams(description);

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

/// One imported video frame and everything its Metal texture is derived from.
///
/// Core Video requires the texture wrapper returned by
/// `CVMetalTextureCacheCreateTextureFromImage` to outlive GPU use of the
/// texture it vends; retaining the `MTLTexture` alone does not satisfy that
/// contract. The pixel buffer is retained for the same reason, because an
/// imported frame outlives the decoder slot it came from. A lease is released
/// exactly once, through `ReleaseAppleVideoFrameLease`.
struct AppleVideoFrameLease {
    void*             pixel_buffer { nullptr };
    /// Retained wrapper per plane; a single-plane import uses only the first.
    CVMetalTextureRef plane_wrappers[2] { nullptr, nullptr };
    /// Retained id<MTLTexture>, or null once the destination was handed back.
    void*             texture { nullptr };
    /// Set when `texture` is a conversion destination the pool can reuse.
    bool              recyclable_destination { false };
};

struct AppleVideoMetalTexturePool::Impl {
    id<MTLDevice>          device;
    VideoConversionBudget  budget {};
    /// Resources the budget handed back; released outside its ledger.
    std::vector<void*>     reclaimed;
    uint64_t               recycles { 0 };
    /// One line per refusal reason and per partially-hosted shape, so an
    /// exhausted budget is visible in the log without printing per frame.
    uint32_t               reported_refusals { 0 };
    VideoConversionSlotKey reported_partial_shape {};
    VideoConversionSlotKey reported_over_ceiling_shape {};

    explicit Impl(void* handle) : device((__bridge id<MTLDevice>)handle) {
        reclaimed.reserve(VideoConversionBudget::kCoexistingSlots);
    }

    [[nodiscard]] static VideoConversionSlotKey KeyFor(uint32_t width, uint32_t height) {
        return { width, height, static_cast<uint32_t>(kConversionDestinationPixelFormat) };
    }

    void releaseReclaimed() noexcept {
        for (void* resource : reclaimed) ReleaseAppleVideoMetalTexture(resource);
        reclaimed.clear();
    }

    void reportRefusal(VideoConversionRefusal refusal) noexcept {
        const uint32_t bit = 1u << static_cast<uint32_t>(refusal);
        if ((reported_refusals & bit) != 0) return;
        reported_refusals |= bit;
        LOG_INFO("video conversion destination not pooled: %s (ceiling %llu bytes)",
                 VideoConversionRefusalName(refusal),
                 static_cast<unsigned long long>(budget.ceiling_bytes()));
    }

    /// Degradation this shape has to live with: the ceiling holds fewer than
    /// the slots that can coexist, so some frames keep allocating.
    void reportPartialHosting(const VideoConversionSlotKey& key, uint64_t bytes) noexcept {
        if (budget.HostsAllSlots(bytes)) return;
        if (reported_partial_shape == key) return;
        reported_partial_shape = key;
        LOG_INFO("video conversion reuse is partial for %ux%u: %llu slots of %llu bytes need "
                 "%llu bytes, ceiling is %llu",
                 key.width,
                 key.height,
                 static_cast<unsigned long long>(VideoConversionBudget::kCoexistingSlots),
                 static_cast<unsigned long long>(bytes),
                 static_cast<unsigned long long>(
                     VideoConversionBudget::RequiredBytesForAllSlots(bytes)),
                 static_cast<unsigned long long>(budget.ceiling_bytes()));
    }

    /// The budget's view of a reservation the header keeps opaque. Both
    /// directions are plain field copies: a reservation owns nothing, so there
    /// is no ownership to get wrong here.
    [[nodiscard]] static VideoConversionReservation ToBudget(
        const AppleVideoConversionReservation& reservation) noexcept {
        // Field order follows VideoConversionReservation's declaration order,
        // which designated initializers require.
        return {
            .granted = reservation.granted,
            .over_ceiling = reservation.over_ceiling,
            .estimated_bytes = reservation.estimated_bytes,
            .refusal = static_cast<VideoConversionRefusal>(reservation.refusal),
            .first_unsatisfiable_report = reservation.first_unsatisfiable_report,
            .in_flight_cap_breached = reservation.in_flight_cap_breached,
            .first_in_flight_cap_report = reservation.first_in_flight_cap_report,
        };
    }

    /// More destinations in flight than the structural expectation accounts
    /// for. Reported, never refused: refusing here would withhold the import
    /// whose delivery is what makes a consumer release the destination the
    /// next request needs, so the texture would stop advancing permanently.
    /// Once per episode — the budget decides when a new one starts.
    void reportInFlightCapBreach(const VideoConversionSlotKey& key, uint32_t cap) noexcept {
        LOG_INFO("video conversion destinations in flight for %ux%u exceed the expected %u "
                 "(%llu on loan); still granting, because refusing would stop the destinations "
                 "coming back at all",
                 key.width,
                 key.height,
                 cap,
                 static_cast<unsigned long long>(budget.loan_count()));
    }

    /// A destination was allocated the ceiling had no room for. The frame is
    /// worth more than the ceiling, so this is reported rather than refused.
    void reportOverCeiling(const VideoConversionSlotKey& key, uint64_t estimated_bytes) noexcept {
        if (reported_over_ceiling_shape == key) return;
        reported_over_ceiling_shape = key;
        LOG_INFO("video conversion destination granted above the ceiling for %ux%u: %llu more "
                 "bytes on top of %llu live, ceiling is %llu",
                 key.width,
                 key.height,
                 static_cast<unsigned long long>(estimated_bytes),
                 static_cast<unsigned long long>(
                     budget.total_live_conversion_allocation_bytes()),
                 static_cast<unsigned long long>(budget.ceiling_bytes()));
    }
};

AppleVideoMetalTexturePool::AppleVideoMetalTexturePool(void* metal_device)
    : m_impl(std::make_unique<Impl>(metal_device))
{
    // Several renderer instances in one process each hold a ceiling of their
    // own; the domain is what makes the sum of them visible to each. It never
    // reaches into another budget: a budget only ever evicts its own cache.
    m_impl->budget.AttachDomain(&SharedVideoConversionMemoryDomain());
}

AppleVideoMetalTexturePool::~AppleVideoMetalTexturePool()
{
    Clear();
    SharedVideoConversionMemoryDomain().Forget(&m_impl->budget);
}

void* AppleVideoMetalTexturePool::Take(uint32_t width, uint32_t height)
{
    return m_impl->budget.Take(Impl::KeyFor(width, height));
}

void AppleVideoMetalTexturePool::SetInFlightSlotExpectation(std::uint32_t slots) noexcept
{
    // The cache computed this: it is the only object that can see how many
    // video textures it hosts and how many consumers each of them has. The
    // budget floors the value at its single-video-texture default, so a pool
    // that is never told behaves exactly as it did before this existed and
    // publishing can only ever raise the expectation.
    m_impl->budget.SetInFlightSlotCap(slots);
}

AppleVideoConversionReservation AppleVideoMetalTexturePool::ReserveFresh(uint32_t width,
                                                                        uint32_t height)
{
    const VideoConversionSlotKey key = Impl::KeyFor(width, height);
    // The estimate is the nominal cost, which is all anyone can know before
    // the texture exists. CommitFresh replaces it with what Metal allocated.
    const VideoConversionReservation reservation = m_impl->budget.ReserveAllocation(
        key, NominalConversionDestinationBytes(width, height), m_impl->reclaimed);
    m_impl->releaseReclaimed();
    if (reservation.over_ceiling) m_impl->reportOverCeiling(key, reservation.estimated_bytes);
    if (reservation.first_in_flight_cap_report) {
        m_impl->reportInFlightCapBreach(key, m_impl->budget.in_flight_slot_cap());
    }
    return {
        .granted = reservation.granted,
        .over_ceiling = reservation.over_ceiling,
        .estimated_bytes = reservation.estimated_bytes,
        .refusal = static_cast<uint32_t>(reservation.refusal),
        .first_unsatisfiable_report = reservation.first_unsatisfiable_report,
        .in_flight_cap_breached = reservation.in_flight_cap_breached,
        .first_in_flight_cap_report = reservation.first_in_flight_cap_report,
    };
}

void AppleVideoMetalTexturePool::CommitFresh(const AppleVideoConversionReservation& reservation,
                                             void* destination) noexcept
{
    if (destination == nullptr) {
        // The allocation the reservation was for never happened.
        m_impl->budget.CancelReservation(Impl::ToBudget(reservation));
        return;
    }
    id<MTLTexture> texture = (__bridge id<MTLTexture>)destination;
    const VideoConversionSlot slot {
        .key = { static_cast<uint32_t>(texture.width),
                 static_cast<uint32_t>(texture.height),
                 static_cast<uint32_t>(texture.pixelFormat) },
        // Metal's own figure. A width * height * 4 product is not this number.
        .bytes = texture.allocatedSize,
        .resource = destination,
    };
    m_impl->budget.CommitAllocation(Impl::ToBudget(reservation), slot);
    m_impl->reportPartialHosting(slot.key, slot.bytes);
}

void AppleVideoMetalTexturePool::CancelFresh(
    const AppleVideoConversionReservation& reservation) noexcept
{
    m_impl->budget.CancelReservation(Impl::ToBudget(reservation));
}

void AppleVideoMetalTexturePool::MarkGpuPending(void* destination) noexcept
{
    m_impl->budget.MarkAwaitingGpu(destination);
}

void AppleVideoMetalTexturePool::EndLoan(void* retained_destination) noexcept
{
    if (retained_destination == nullptr) return;
    m_impl->budget.EndLoan(retained_destination);
    ReleaseAppleVideoMetalTexture(retained_destination);
}

void AppleVideoMetalTexturePool::Recycle(void* retained_destination) noexcept
{
    if (retained_destination == nullptr) return;
    id<MTLTexture> texture = (__bridge id<MTLTexture>)retained_destination;
    const uint32_t width = static_cast<uint32_t>(texture.width);
    const uint32_t height = static_cast<uint32_t>(texture.height);
    if (!CompatibleConvertedDestination(texture, m_impl->device, width, height)) {
        // Not a texture this pool could ever lend out for a conversion.
        m_impl->budget.EndLoan(retained_destination);
        ReleaseAppleVideoMetalTexture(retained_destination);
        return;
    }

    const VideoConversionSlot slot {
        .key = { width, height, static_cast<uint32_t>(texture.pixelFormat) },
        .bytes = texture.allocatedSize,
        .resource = retained_destination,
    };
    // The caller reached this point only after the GPU finished with the
    // destination, which is what ends the loan the lend opened.
    m_impl->budget.ReportGpuComplete(retained_destination);
    if (DeviceIsUnderMemoryPressure(m_impl->device, slot.bytes)) {
        m_impl->budget.ReportMemoryPressure(m_impl->reclaimed);
    } else {
        m_impl->budget.ClearMemoryPressure();
    }
    m_impl->reportPartialHosting(slot.key, slot.bytes);

    const auto admission = m_impl->budget.Admit(slot, m_impl->reclaimed);
    m_impl->releaseReclaimed();
    if (!admission.accepted) {
        m_impl->reportRefusal(admission.refusal);
        ReleaseAppleVideoMetalTexture(retained_destination);
        return;
    }
    ++m_impl->recycles;
}

void AppleVideoMetalTexturePool::RetainOnly(uint32_t width, uint32_t height) noexcept
{
    m_impl->budget.DropOtherKeys(Impl::KeyFor(width, height), m_impl->reclaimed);
    m_impl->releaseReclaimed();
}

void AppleVideoMetalTexturePool::ReportAllocationFailure(uint32_t width, uint32_t height) noexcept
{
    m_impl->budget.ReportAllocationFailure(NominalConversionDestinationBytes(width, height),
                                           m_impl->reclaimed);
    m_impl->releaseReclaimed();
}

void AppleVideoMetalTexturePool::Clear() noexcept
{
    m_impl->budget.Drain(m_impl->reclaimed);
    m_impl->releaseReclaimed();
    // A new scene may well fit what this one could not.
    m_impl->budget.Reset();
}

AppleVideoConversionPoolStats AppleVideoMetalTexturePool::Stats() const noexcept
{
    const auto& budget = m_impl->budget;
    return {
        .cached_texture_count = budget.available_cached_count(),
        .cached_bytes = budget.available_cached_bytes(),
        .peak_cached_bytes = budget.peak_available_cached_bytes(),
        .checked_out_bytes = budget.checked_out_bytes(),
        .awaiting_gpu_bytes = budget.awaiting_gpu_completion_bytes(),
        .live_bytes = budget.total_live_conversion_allocation_bytes(),
        .peak_live_bytes = budget.peak_live_conversion_allocation_bytes(),
        .reserved_estimate_bytes = budget.reserved_estimate_bytes(),
        .over_ceiling_grants = budget.over_ceiling_grants(),
        .live_slot_count = budget.live_slot_count(),
        .hits = budget.hits(),
        .misses = budget.misses(),
        .recycles = m_impl->recycles,
        .evictions = budget.evictions(),
        .refusals = budget.refusals(),
        .in_flight_cap_breaches = budget.in_flight_cap_breaches(),
    };
}

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

void* CreateAppleVideoFrameLease(const VideoTextureFrame& frame,
                                 void* metal_device,
                                 void* reusable_destination,
                                 std::string* error,
                                 bool* destination_allocation_failed,
                                 void** created_destination)
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

        id<MTLTexture>    texture = nil;
        CVMetalTextureRef wrapper = nullptr;
        bool              recyclable_destination = false;
        const OSType pixel_format = static_cast<OSType>(frame.pixel_format);
        const bool is_nv12 = pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        id<MTLTexture> destination = (__bridge id<MTLTexture>)reusable_destination;
        if (destination != nil &&
            (!is_nv12 || !CompatibleConvertedDestination(destination, device, frame.width, frame.height))) {
            return SetError(error, "incompatible reusable NV12 conversion destination"), nullptr;
        }
        if (is_nv12 && frame.pixel_buffer == nullptr) {
            return SetError(error, "NV12 conversion requires a pixel buffer"), nullptr;
        }
        if (pixel_format == kCVPixelFormatType_32BGRA && frame.io_surface != nullptr) {
            // An IOSurface-backed texture owns its own backing; no Core Video
            // wrapper is involved.
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
                &wrapper,
                error);
        } else if (is_nv12) {
            // The conversion writes an ordinary destination texture and waits
            // for completion, so its plane wrappers are already retired; the
            // destination itself is what the pool can take back.
            texture = CreateConvertedMetalTexture(
                device,
                reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer),
                pixel_format,
                frame.width,
                frame.height,
                destination,
                destination_allocation_failed,
                error);
            recyclable_destination = texture != nil;
        } else if (frame.io_surface != nullptr && frame.pixel_buffer == nullptr) {
            texture = CreateDirectMetalTexture(
                device,
                reinterpret_cast<IOSurfaceRef>(frame.io_surface),
                frame.width,
                frame.height,
                error);
        }
        if (texture == nil) {
            if (wrapper != nullptr) CFRelease(wrapper);
            if (error != nullptr && error->empty()) {
                SetError(error, "failed to create Metal texture for imported video frame");
            }
            return nullptr;
        }

        auto* lease = new AppleVideoFrameLease {};
        lease->texture = (__bridge_retained void*)texture;
        lease->plane_wrappers[0] = wrapper;
        lease->recyclable_destination = recyclable_destination;
        if (created_destination != nullptr && recyclable_destination &&
            reusable_destination == nullptr) {
            // The same handle Recycle will later be given, so the budget's
            // ledger keys on one identity from allocation to release. Borrowed:
            // the retain above stays with the lease.
            *created_destination = lease->texture;
        }
        if (frame.pixel_buffer != nullptr) {
            // The import can outlive the decoder slot the frame came from.
            lease->pixel_buffer =
                const_cast<void*>(CFRetain(reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer)));
        }
        return lease;
    }
}

void* AppleVideoFrameLeaseTexture(void* lease)
{
    return lease != nullptr ? static_cast<AppleVideoFrameLease*>(lease)->texture : nullptr;
}

void* TakeAppleVideoFrameLeaseDestination(void* lease)
{
    if (lease == nullptr) return nullptr;
    auto* owned = static_cast<AppleVideoFrameLease*>(lease);
    if (!owned->recyclable_destination) return nullptr;
    // Ownership of the retain moves to the caller; the lease must not release
    // the same texture again.
    void* destination = owned->texture;
    owned->texture = nullptr;
    owned->recyclable_destination = false;
    return destination;
}

void ReleaseAppleVideoFrameLease(void* lease)
{
    if (lease == nullptr) return;

    @autoreleasepool {
        auto* owned = static_cast<AppleVideoFrameLease*>(lease);
        for (auto& wrapper : owned->plane_wrappers) {
            if (wrapper != nullptr) {
                CFRelease(wrapper);
                wrapper = nullptr;
            }
        }
        if (owned->texture != nullptr) {
            (void)CFBridgingRelease(owned->texture);
            owned->texture = nullptr;
        }
        if (owned->pixel_buffer != nullptr) {
            CFRelease(reinterpret_cast<CVPixelBufferRef>(owned->pixel_buffer));
            owned->pixel_buffer = nullptr;
        }
        delete owned;
    }
}

void ReleaseAppleVideoMetalTexture(void* handle)
{
    if (handle == nullptr) return;

    @autoreleasepool {
        (void)CFBridgingRelease(handle);
    }
}

} // namespace wallpaper::video
