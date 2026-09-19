#include "MetalVideoTextures.hpp"

#include "MetalRender/MetalVideoSupport.hpp"

#import <CoreVideo/CoreVideo.h>

#include "Core/RendererCounters.hpp"
#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Video/SharedVideoSession.hpp"
#include "Video/VideoColorConversion.hpp"
#include "Video/VideoFramePacing.hpp"
// For `ResolveEffectiveVideoPlaybackState`: the global/per-layer combination is
// part of what playback means, and a second copy of it here would be a second
// definition that can drift from the compatibility backend's.
#include "Vulkan/TextureCache.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <map>
#include <utility>

namespace wallpaper::metal
{
namespace
{

/// What author shaders sample, on both import paths. Keeping the zero-copy
/// BGRA frame and the converted NV12 frame in one format means a shader cannot
/// tell which decoder produced its texture.
constexpr MTLPixelFormat kVideoDestinationPixelFormat = MTLPixelFormatBGRA8Unorm;

/// Conversion destinations per source: the renderer's two in-flight frames plus
/// the one this frame writes. A destination a command buffer may still be
/// reading is therefore never the one chosen next.
constexpr std::size_t kDestinationSlots = 3;

/// Frames between opportunistic `CVMetalTextureCacheFlush` calls. Flushing
/// every frame would drop the cache's own reuse, which is the only reason the
/// per-frame import is cheap; never flushing keeps dead surfaces mapped.
constexpr std::uint64_t kTextureCacheFlushInterval = 64;

/// Mirrors the kernel `FfmpegVideoInterop.mm` uses field for field, including
/// the `YuvColorParams` layout, so the compatibility backend and this one
/// cannot disagree about range, matrix or alpha for the same frame.
constexpr const char* kNv12ConversionShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

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

kernel void owe_scene_nv12_to_bgra(texture2d<float, access::sample> y_texture [[texture(0)]],
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

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

std::string DescribePixelFormat(std::uint32_t pixel_format)
{
    const char chars[5] {
        static_cast<char>((pixel_format >> 24) & 0xff),
        static_cast<char>((pixel_format >> 16) & 0xff),
        static_cast<char>((pixel_format >> 8) & 0xff),
        static_cast<char>(pixel_format & 0xff),
        0,
    };
    return std::string(chars);
}

/// SDR 8-bit only, and deliberately so: 10-bit, HDR transfer functions and
/// every other chroma layout need colour handling this path does not have, and
/// guessing one would show wrong colours rather than fall back.
bool SupportedPixelFormat(std::uint32_t pixel_format, bool* is_nv12)
{
    switch (pixel_format) {
    case kCVPixelFormatType_32BGRA:
        if (is_nv12 != nullptr) *is_nv12 = false;
        return true;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        if (is_nv12 != nullptr) *is_nv12 = true;
        return true;
    default:
        return false;
    }
}

} // namespace

/// Members of `MetalVideoTextures::State`, which is declared in a header, so
/// these need a linkage the anonymous namespace above cannot give them.
namespace video_detail
{

/// Everything one imported frame's texture depends on, released together.
///
/// Core Video documents the wrapper, not the vended `MTLTexture`, as the object
/// whose lifetime governs the texture's validity, and the pixel buffer outlives
/// the decoder slot it came from, so all three are held here rather than
/// assumed alive.
struct FrameBundle {
    video::VideoTextureFrame frame {};
    CVMetalTextureRef        wrappers[2] { nullptr, nullptr };
    /// What author shaders sample: the vended BGRA texture, or the conversion
    /// destination the NV12 kernel wrote.
    id<MTLTexture>           sampled { nil };
    id<MTLTexture>           destination { nil };
    /// Cleared when this bundle dies, which is after the command buffer that
    /// read `destination` completed. Until then the slot is not offered again.
    std::shared_ptr<std::atomic<bool>> slot_busy;

    FrameBundle() = default;
    FrameBundle(const FrameBundle&)            = delete;
    FrameBundle& operator=(const FrameBundle&) = delete;

    ~FrameBundle()
    {
        if (slot_busy) slot_busy->store(false, std::memory_order_release);
        for (auto& wrapper : wrappers) {
            if (wrapper != nullptr) {
                CFRelease(wrapper);
                wrapper = nullptr;
            }
        }
        video::ReleaseAppleVideoFrame(&frame);
    }
};

/// The frames one command buffer read. Held by a `shared_ptr` the completion
/// handler captures, so the handler owns what it must outlive without owning
/// the renderer.
struct PendingFrames {
    std::vector<std::shared_ptr<FrameBundle>> bundles;
};

struct DestinationSlot {
    id<MTLTexture>                     texture { nil };
    std::shared_ptr<std::atomic<bool>> busy;
};

struct VideoSourceEntry {
    std::shared_ptr<video::VideoTextureSource> source;
    /// Keeps the currently sampled frame alive between frames; replaced only
    /// when a newer generation is imported.
    std::shared_ptr<FrameBundle>               current;
    id<MTLTexture>                             texture { nil };
    std::uint64_t                              imported_generation { 0 };
    bool                                       has_import { false };
    std::uint32_t                              width { 0 };
    std::uint32_t                              height { 0 };
    std::array<DestinationSlot, kDestinationSlots> slots {};
    /// What the last `syncPlayback` actually asked for, which is what decides
    /// whether this source still changes on its own.
    bool                                       advancing { true };
    video::VideoFrameSelectionTracker          selection;
    std::uint64_t                              reported_decode_outputs { 0 };
    std::uint64_t                              reported_seeks { 0 };
};

} // namespace video_detail

using namespace video_detail;

struct MetalVideoTextures::State {
    id<MTLDevice>               device { nil };
    CVMetalTextureCacheRef      texture_cache { nullptr };
    id<MTLComputePipelineState> nv12_pipeline { nil };
    /// Why the conversion pipeline is missing, kept from `configure` so the
    /// first frame that needs it can say something better than "no pipeline".
    std::string                 pipeline_error;

    std::map<std::string, VideoSourceEntry> sources;
    RendererCounters*                       counters { nullptr };
    bool                                    paused { false };
    float                                   rate { 1.0f };
    std::uint64_t                           frames { 0 };
    std::uint64_t                           conversions_encoded { 0 };
    std::uint64_t                           imports { 0 };

    /// Entries go before the device objects they were made from, so nothing
    /// outlives the cache it came out of within this object.
    ~State()
    {
        sources.clear();
        releaseDeviceObjects();
    }

    void releaseDeviceObjects()
    {
        if (texture_cache != nullptr) {
            CFRelease(texture_cache);
            texture_cache = nullptr;
        }
        nv12_pipeline = nil;
        device        = nil;
    }

    /// Pipeline and Core Video cache both belong to one device, so they are
    /// built together and thrown away together.
    void buildDeviceObjects()
    {
        CVMetalTextureCacheRef cache = nullptr;
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &cache) ==
                kCVReturnSuccess &&
            cache != nullptr) {
            texture_cache = cache;
        } else {
            pipeline_error = "failed to create a Core Video texture cache for this Metal device";
            return;
        }

        NSError*  library_error = nil;
        NSString* source        = [NSString stringWithUTF8String:kNv12ConversionShaderSource];
        id<MTLLibrary> library =
            [device newLibraryWithSource:source options:nil error:&library_error];
        if (library == nil) {
            pipeline_error = library_error != nil
                                 ? std::string([[library_error localizedDescription] UTF8String])
                                 : "failed to compile the NV12 video conversion library";
            return;
        }
        id<MTLFunction> function = [library newFunctionWithName:@"owe_scene_nv12_to_bgra"];
        if (function == nil) {
            pipeline_error = "failed to load the NV12 video conversion function";
            return;
        }
        NSError* creation_error = nil;
        nv12_pipeline = [device newComputePipelineStateWithFunction:function error:&creation_error];
        if (nv12_pipeline == nil) {
            pipeline_error = creation_error != nil
                                 ? std::string([[creation_error localizedDescription] UTF8String])
                                 : "failed to create the NV12 video conversion pipeline";
        }
    }

    void reportSourceWork(VideoSourceEntry& entry, std::uint64_t generation)
    {
        if (counters == nullptr) return;
        const auto stats = entry.source->sourceStats();
        if (stats.decoded_frames > entry.reported_decode_outputs) {
            counters->Add(OWE_RC_VIDEO_DECODE_OUTPUTS,
                          stats.decoded_frames - entry.reported_decode_outputs);
            entry.reported_decode_outputs = stats.decoded_frames;
        }
        if (stats.seek_requests > entry.reported_seeks) {
            counters->Add(OWE_RC_VIDEO_SEEKS, stats.seek_requests - entry.reported_seeks);
            entry.reported_seeks = stats.seek_requests;
        }
        const auto selection = entry.selection.Observe(generation);
        if (selection.selected) {
            counters->Add(OWE_RC_VIDEO_FRAMES_SELECTED);
            counters->Set(OWE_RC_VIDEO_SELECTED_GENERATION, generation);
        }
        if (selection.reused) counters->Add(OWE_RC_VIDEO_FRAMES_REUSED);
        if (selection.skipped > 0) counters->Add(OWE_RC_VIDEO_FRAMES_SKIPPED, selection.skipped);
    }

    void publishSourceIdentity()
    {
        if (counters == nullptr) return;
        std::uint64_t live_sources    = 0;
        std::uint64_t single_instance = 0;
        for (const auto& [key, entry] : sources) {
            (void)key;
            if (! entry.source) continue;
            ++live_sources;
            single_instance = entry.source->sourceStats().instance_id;
        }
        counters->Set(OWE_RC_VIDEO_SOURCE_COUNT, live_sources);
        counters->Set(OWE_RC_VIDEO_SOURCE_INSTANCE, live_sources == 1 ? single_instance : 0);
    }

    /// A destination no command buffer is still reading, allocating it the
    /// first time the slot is used. Nil means every slot is in flight or Metal
    /// refused one, which the caller treats as "no new frame this tick" rather
    /// than as a failure.
    id<MTLTexture> acquireDestination(VideoSourceEntry& entry,
                                      std::uint32_t     width,
                                      std::uint32_t     height,
                                      DestinationSlot** out_slot)
    {
        if (entry.width != width || entry.height != height) {
            // A shape nothing requests any more is not worth its bytes. Frames
            // still in flight hold their own reference to the old texture, so
            // dropping the slots here cannot pull one out from under them.
            entry.slots  = {};
            entry.width  = width;
            entry.height = height;
        }

        for (auto& slot : entry.slots) {
            if (slot.busy && slot.busy->load(std::memory_order_acquire)) continue;
            if (slot.texture == nil) {
                MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:kVideoDestinationPixelFormat
                                                 width:width
                                                height:height
                                             mipmapped:NO];
                descriptor.usage           = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                descriptor.storageMode     = MTLStorageModePrivate;
                descriptor.resourceOptions = MTLResourceStorageModePrivate;
                slot.texture               = [device newTextureWithDescriptor:descriptor];
                if (slot.texture == nil) return nil;
            }
            if (! slot.busy) slot.busy = std::make_shared<std::atomic<bool>>(false);
            slot.busy->store(true, std::memory_order_release);
            *out_slot = &slot;
            return slot.texture;
        }
        return nil;
    }
};

MetalVideoTextures::MetalVideoTextures(): m_state(std::make_shared<State>()) {}

MetalVideoTextures::~MetalVideoTextures() = default;

void MetalVideoTextures::configure(id<MTLDevice> device)
{
    auto& state = *m_state;
    if (state.device == device) return;
    state.sources.clear();
    state.releaseDeviceObjects();
    state.pipeline_error.clear();
    state.device = device;
    if (device == nil) return;
    state.buildDeviceObjects();
}

bool MetalVideoTextures::prepare(Scene&                          scene,
                                 const std::vector<std::string>& texture_keys,
                                 std::string*                    error)
{
    auto& state = *m_state;
    if (texture_keys.empty()) return true;
    if (state.device == nil) {
        return SetError(error, "no Metal device for the scene's video textures");
    }
    if (state.texture_cache == nullptr) {
        return SetError(error,
                        state.pipeline_error.empty()
                            ? std::string("no Core Video texture cache for the scene's video "
                                          "textures")
                            : state.pipeline_error);
    }

    for (const auto& key : texture_keys) {
        if (key.empty() || state.sources.count(key) != 0) continue;

        if (auto reason = MetalVideoTextureRejection(scene, key); ! reason.empty()) {
            return SetError(error, std::move(reason));
        }
        if (scene.imageParser == nullptr) {
            return SetError(error, "the scene cannot resolve video texture \"" + key + "\"");
        }
        auto image = scene.imageParser->Parse(key);
        if (! image) {
            return SetError(error, "failed to parse video texture \"" + key + "\"");
        }
        // Not every key handed in is a video; the ones that are not belong to
        // the ordinary texture path and are simply not ours.
        if (! image->header.isVideo) continue;

        std::string source_error;
        // Through the registry, exactly as the compatibility backend's texture
        // cache does: with shared decode off this is a private source per
        // call, and with it on an equivalent running decoder is reused.
        auto source = video::AcquireVideoTextureSource(*image, &source_error);
        if (! source) {
            return SetError(error,
                            "failed to open video texture \"" + key + "\": " + source_error);
        }
        if (! source->prime(&source_error)) {
            return SetError(error,
                            "failed to prime video texture \"" + key + "\": " + source_error);
        }
        // The first frame is what proves the media plays at all and what the
        // format rejection below is decided on. Importing it is the render
        // thread's job, because the import has to be encoded into a command
        // buffer this call does not have.
        if (! source->syncPlayback(video::VideoPlaybackState {}, &source_error) ||
            ! source->refreshFrame(&source_error)) {
            return SetError(error,
                            "failed to read the first frame of video texture \"" + key +
                                "\": " + source_error);
        }
        const auto frame = source->currentFrame();
        if (! frame.valid()) {
            return SetError(error, "video texture \"" + key + "\" produced no first frame");
        }
        bool is_nv12 = false;
        if (! SupportedPixelFormat(frame.pixel_format, &is_nv12)) {
            return SetError(error,
                            "video texture \"" + key + "\" decodes to the unsupported pixel " +
                                "format " + DescribePixelFormat(frame.pixel_format));
        }
        if (is_nv12 && state.nv12_pipeline == nil) {
            return SetError(error,
                            state.pipeline_error.empty()
                                ? std::string("no NV12 conversion pipeline for video textures")
                                : state.pipeline_error);
        }

        VideoSourceEntry entry;
        entry.source = std::move(source);
        state.sources.emplace(key, std::move(entry));
    }

    state.publishSourceIdentity();
    return true;
}

#ifdef WESCENE_BUILD_TESTS
bool MetalVideoTextures::prepareForTests(const std::string&                         key,
                                         std::shared_ptr<video::VideoTextureSource> source,
                                         std::string*                               error)
{
    auto& state = *m_state;
    if (state.device == nil || state.texture_cache == nullptr) {
        return SetError(error, "MetalVideoTextures was not configured with a Metal device");
    }
    if (! source) return SetError(error, "a test video source must not be null");
    if (! source->prime(error) || ! source->refreshFrame(error)) return false;
    const auto frame = source->currentFrame();
    if (! frame.valid()) return SetError(error, "the test video source produced no first frame");
    if (! SupportedPixelFormat(frame.pixel_format, nullptr)) {
        return SetError(error,
                        "the test video source decodes to the unsupported pixel format " +
                            DescribePixelFormat(frame.pixel_format));
    }
    VideoSourceEntry entry;
    entry.source = std::move(source);
    state.sources.insert_or_assign(key, std::move(entry));
    return true;
}

std::uint64_t MetalVideoTextures::conversionsEncodedForTests() const
{
    return m_state->conversions_encoded;
}

std::uint64_t MetalVideoTextures::importsForTests() const { return m_state->imports; }
#endif

void MetalVideoTextures::release()
{
    // Sources and slot textures go; anything a command buffer is still reading
    // is owned by that command buffer's pending block and outlives this call.
    m_state->sources.clear();
    if (m_state->texture_cache != nullptr) CVMetalTextureCacheFlush(m_state->texture_cache, 0);
}

bool MetalVideoTextures::owns(const std::string& key) const
{
    return m_state->sources.count(key) != 0;
}

bool MetalVideoTextures::empty() const { return m_state->sources.empty(); }

void MetalVideoTextures::setPaused(bool paused) { m_state->paused = paused; }

void MetalVideoTextures::setRate(float rate) { m_state->rate = rate; }

void MetalVideoTextures::setCounters(RendererCounters* counters)
{
    m_state->counters = counters;
}

double MetalVideoTextures::shortestFramePeriod() const
{
    double shortest = 0.0;
    for (const auto& [key, entry] : m_state->sources) {
        (void)key;
        if (! entry.source) continue;
        const double period = entry.source->frameDurationSeconds();
        // A source that cannot report its rate makes the whole answer unknown:
        // pacing on the others could skip its changes.
        if (! (period > 0.0)) return 0.0;
        if (shortest == 0.0 || period < shortest) shortest = period;
    }
    return shortest;
}

bool MetalVideoTextures::advancesOnItsOwn() const
{
    for (const auto& [key, entry] : m_state->sources) {
        (void)key;
        if (entry.source && entry.advancing) return true;
    }
    return false;
}

id<MTLTexture> MetalVideoTextures::texture(const std::string& key) const
{
    const auto iterator = m_state->sources.find(key);
    return iterator == m_state->sources.end() ? nil : iterator->second.texture;
}

bool MetalVideoTextures::beginFrame(Scene& scene, id<MTLCommandBuffer> command, std::string* error)
{
    auto& state = *m_state;
    if (state.sources.empty()) return true;
    if (command == nil) return SetError(error, "video textures need a command buffer to import into");

    auto pending = std::make_shared<PendingFrames>();
    id<MTLComputeCommandEncoder> encoder = nil;

    const bool ok = [&]() -> bool {
        for (auto& [key, entry] : state.sources) {
            if (! entry.source) continue;

            video::VideoPlaybackState layer_state =
                scene.runtime != nullptr
                    ? scene.runtime->ResolveVideoPlaybackState(key, scene.elapsingTime)
                    : video::VideoPlaybackState {};
            if (scene.runtime == nullptr) layer_state.scene_elapsed_seconds = scene.elapsingTime;
            video::VideoPlaybackState global_state {};
            global_state.paused = state.paused;
            global_state.rate   = state.rate;
            const auto effective =
                vulkan::ResolveEffectiveVideoPlaybackState(global_state, layer_state);
            entry.advancing = ! effective.paused && effective.rate > 0.0f;

            if (! entry.source->syncPlayback(effective, error)) return false;
            if (! entry.source->refreshFrame(error)) return false;

            const auto current = entry.source->currentFrame();
            if (! current.valid()) {
                // Nothing decoded yet. That is only a failure while there is
                // also nothing on screen to keep showing.
                if (entry.has_import) continue;
                return SetError(error, "video texture \"" + key + "\" has no frame to display");
            }
            state.reportSourceWork(entry, current.generation);
            // A generation already imported is already on screen. Passes that
            // sample it several times share this one texture; nothing is
            // converted twice, and a paused or suspended source lands here.
            if (entry.has_import && entry.imported_generation == current.generation) continue;

            auto bundle = std::make_shared<FrameBundle>();
            // Retained under the producer's own lock where the source can do
            // it, so the frame cannot be released between the read and the
            // retain.
            if (! entry.source->retainCurrentFrame(&bundle->frame)) {
                video::RetainAppleVideoFrame(current, &bundle->frame);
            }
            if (! bundle->frame.valid()) {
                return SetError(error,
                                "failed to retain the current frame of video texture \"" + key +
                                    "\"");
            }
            const auto& frame = bundle->frame;
            bool        is_nv12 = false;
            if (! SupportedPixelFormat(frame.pixel_format, &is_nv12)) {
                return SetError(error,
                                "video texture \"" + key + "\" changed to the unsupported pixel " +
                                    "format " + DescribePixelFormat(frame.pixel_format));
            }
            auto pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer);
            if (pixel_buffer == nullptr) {
                return SetError(error,
                                "video texture \"" + key + "\" produced a frame with no pixel "
                                                           "buffer");
            }

            if (! is_nv12) {
                const CVReturn result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              kVideoDestinationPixelFormat,
                                                              frame.width,
                                                              frame.height,
                                                              0,
                                                              &bundle->wrappers[0]);
                if (result != kCVReturnSuccess || bundle->wrappers[0] == nullptr) {
                    return SetError(error,
                                    "failed to import the BGRA frame of video texture \"" + key +
                                        "\"");
                }
                bundle->sampled = CVMetalTextureGetTexture(bundle->wrappers[0]);
                if (bundle->sampled == nil) {
                    return SetError(error,
                                    "Core Video returned no texture for video texture \"" + key +
                                        "\"");
                }
            } else {
                if (state.nv12_pipeline == nil) {
                    return SetError(error,
                                    state.pipeline_error.empty()
                                        ? std::string("no NV12 conversion pipeline for video "
                                                      "textures")
                                        : state.pipeline_error);
                }
                const CVReturn luma_result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              MTLPixelFormatR8Unorm,
                                                              frame.width,
                                                              frame.height,
                                                              0,
                                                              &bundle->wrappers[0]);
                const CVReturn chroma_result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              MTLPixelFormatRG8Unorm,
                                                              frame.width / 2u,
                                                              frame.height / 2u,
                                                              1,
                                                              &bundle->wrappers[1]);
                if (luma_result != kCVReturnSuccess || bundle->wrappers[0] == nullptr ||
                    chroma_result != kCVReturnSuccess || bundle->wrappers[1] == nullptr) {
                    return SetError(error,
                                    "failed to import the NV12 planes of video texture \"" + key +
                                        "\"");
                }
                id<MTLTexture> luma   = CVMetalTextureGetTexture(bundle->wrappers[0]);
                id<MTLTexture> chroma = CVMetalTextureGetTexture(bundle->wrappers[1]);
                if (luma == nil || chroma == nil) {
                    return SetError(error,
                                    "Core Video returned no plane textures for video texture \"" +
                                        key + "\"");
                }

                DestinationSlot* slot = nullptr;
                id<MTLTexture>   destination =
                    state.acquireDestination(entry, frame.width, frame.height, &slot);
                if (destination == nil) {
                    // Either every destination is still being read, or Metal
                    // refused one. Neither is a reason to fail the scene: the
                    // frame already on screen stays there.
                    continue;
                }
                bundle->destination = destination;
                bundle->sampled     = destination;
                bundle->slot_busy   = slot->busy;

                if (encoder == nil) {
                    encoder = [command computeCommandEncoder];
                    if (encoder == nil) {
                        return SetError(error,
                                        "failed to create a compute encoder for video texture "
                                        "conversion");
                    }
                    encoder.label = @"owe video texture conversion";
                }
                const video::YuvColorParams params = video::AppleVideoFrameColorParams(frame);
                [encoder setComputePipelineState:state.nv12_pipeline];
                [encoder setTexture:luma atIndex:0];
                [encoder setTexture:chroma atIndex:1];
                [encoder setTexture:destination atIndex:2];
                [encoder setBytes:&params length:sizeof(params) atIndex:0];
                const NSUInteger thread_width =
                    std::min<NSUInteger>(16u, state.nv12_pipeline.threadExecutionWidth);
                const NSUInteger thread_height = std::max<NSUInteger>(
                    1u, state.nv12_pipeline.maxTotalThreadsPerThreadgroup / thread_width);
                const MTLSize threads_per_group =
                    MTLSizeMake(thread_width, std::min<NSUInteger>(16u, thread_height), 1u);
                [encoder dispatchThreads:MTLSizeMake(frame.width, frame.height, 1u)
                    threadsPerThreadgroup:threads_per_group];
                ++state.conversions_encoded;
                if (state.counters != nullptr) {
                    state.counters->Set(OWE_RC_VIDEO_CONVERSIONS, state.conversions_encoded);
                }
            }

            ++state.imports;
            if (state.counters != nullptr) {
                state.counters->Set(OWE_RC_VIDEO_IMPORTS, state.imports);
            }
            entry.texture             = bundle->sampled;
            entry.imported_generation = frame.generation;
            entry.has_import          = true;
            // The previous bundle is dropped here, which frees its slot unless
            // a command buffer still holds it through `pending`.
            entry.current = bundle;
            pending->bundles.push_back(std::move(bundle));
        }
        return true;
    }();

    if (encoder != nil) [encoder endEncoding];
    if (! pending->bundles.empty()) {
        // The handler owns the frames, not the renderer: it may run after
        // `release()` or after this object is gone, on a thread Metal chose.
        [command addCompletedHandler:^(id<MTLCommandBuffer>) {
            pending->bundles.clear();
        }];
    }
    if (++state.frames % kTextureCacheFlushInterval == 0 && state.texture_cache != nullptr) {
        CVMetalTextureCacheFlush(state.texture_cache, 0);
    }
    return ok;
}

} // namespace wallpaper::metal
