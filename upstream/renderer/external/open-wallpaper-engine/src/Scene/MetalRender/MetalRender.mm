#include "MetalRender/MetalRender.hpp"

#include "Runtime/RuntimeImageSource.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "MetalRender/MetalBlend.hpp"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalProjection.hpp"
#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/SceneMetalProgram.hpp"
#include "MetalRender/ScenePassDescription.hpp"

#include "CopyPass.hpp"
#include "CustomShaderPass.hpp"
#include "PassCommon.hpp"
#include "PrePass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"

#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "Interface/IShaderValueUpdater.h"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"

#include <Eigen/Dense>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_map>
#include <vector>

// The mirrored enumerators the rest of this library is written against have to
// be the framework's own values, or every pipeline is built with plausible
// nonsense. Checked here, where both definitions are visible.
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::Zero == MTLBlendFactorZero, "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::One == MTLBlendFactorOne, "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::SourceColor == MTLBlendFactorSourceColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusSourceColor ==
                  MTLBlendFactorOneMinusSourceColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::SourceAlpha == MTLBlendFactorSourceAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusSourceAlpha ==
                  MTLBlendFactorOneMinusSourceAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::DestinationColor ==
                  MTLBlendFactorDestinationColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusDestinationColor ==
                  MTLBlendFactorOneMinusDestinationColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::DestinationAlpha ==
                  MTLBlendFactorDestinationAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusDestinationAlpha ==
                  MTLBlendFactorOneMinusDestinationAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendOperation::Add == MTLBlendOperationAdd, "");
static_assert((uint32_t)wallpaper::metal::MetalCullMode::None == MTLCullModeNone, "");
static_assert((uint32_t)wallpaper::metal::MetalCullMode::Front == MTLCullModeFront, "");
static_assert((uint32_t)wallpaper::metal::MetalCullMode::Back == MTLCullModeBack, "");
static_assert((uint32_t)wallpaper::metal::MetalLoadAction::DontCare == MTLLoadActionDontCare, "");
static_assert((uint32_t)wallpaper::metal::MetalLoadAction::Load == MTLLoadActionLoad, "");
static_assert((uint32_t)wallpaper::metal::MetalLoadAction::Clear == MTLLoadActionClear, "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::RGBA8Unorm == MTLPixelFormatRGBA8Unorm,
              "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::RGBA8Unorm_sRGB ==
                  MTLPixelFormatRGBA8Unorm_sRGB,
              "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::BGRA8Unorm == MTLPixelFormatBGRA8Unorm,
              "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::BGRA8Unorm_sRGB ==
                  MTLPixelFormatBGRA8Unorm_sRGB,
              "");

namespace wallpaper::metal
{
namespace
{

/// Frames the CPU may run ahead of the GPU. Two is enough to keep the queue
/// fed without letting the wallpaper build a backlog of work nobody will see.
constexpr NSUInteger kFramesInFlight = 2;

/// Vertex buffers are bound from the top of Metal's buffer argument table
/// downwards, because the translated shader's own resources are placed at their
/// SPIR-V binding indices, which start at zero. A collision is detected at
/// prepare time rather than assumed away.
constexpr NSUInteger kVertexBufferTopIndex = 30;

/// Render targets are read by later passes and by the presentation blit, so
/// their contents must outlive the pass that wrote them. Nothing here is ever
/// `memoryless`: a memoryless attachment's contents end with its render pass,
/// which is exactly the lifetime these do not have.
constexpr MTLTextureUsage kRenderTargetUsage =
    MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

constexpr std::string_view kPresentShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct OweVertex {
    float2 position;
    float2 texcoord;
};

struct OweVarying {
    float4 position [[position]];
    float2 texcoord;
};

vertex OweVarying owe_present_vertex(uint vertex_id [[vertex_id]],
                                     const device OweVertex* vertices [[buffer(0)]]) {
    OweVarying out;
    out.position = float4(vertices[vertex_id].position, 0.0, 1.0);
    out.texcoord = vertices[vertex_id].texcoord;
    return out;
}

fragment float4 owe_present_fragment(OweVarying in [[stage_in]],
                                     texture2d<float> source [[texture(0)]],
                                     sampler source_sampler [[sampler(0)]]) {
    return source.sample(source_sampler, in.texcoord);
}
)";

struct PresentVertex
{
    float position[2];
    float texcoord[2];
};

/// A triangle strip covering the target, with the texture's top row at the top
/// of the image. Metal's normalized device coordinates put -1 at the bottom and
/// its textures put v = 0 at the top, so v = 1 belongs with y = -1. These are
/// the same four vertices the compatibility backend's final blit uses, which is
/// what makes the two backends present the same orientation.
constexpr PresentVertex kPresentVertices[4] = {
    { { -1.0f, -1.0f }, { 0.0f, 1.0f } },
    { { -1.0f, 1.0f }, { 0.0f, 0.0f } },
    { { 1.0f, -1.0f }, { 1.0f, 1.0f } },
    { { 1.0f, 1.0f }, { 1.0f, 0.0f } },
};

constexpr PresentVertex kPresentVerticesFlipped[4] = {
    { { -1.0f, -1.0f }, { 1.0f, 1.0f } },
    { { -1.0f, 1.0f }, { 1.0f, 0.0f } },
    { { 1.0f, -1.0f }, { 0.0f, 1.0f } },
    { { 1.0f, 1.0f }, { 0.0f, 0.0f } },
};

double NormalizeScaleFactor(double value)
{
    if (! std::isfinite(value) || value <= 0.0) return 1.0;
    return value;
}

MTLVertexFormat ToMetalVertexFormat(std::string_view name)
{
    if (name == "r32_sfloat") return MTLVertexFormatFloat;
    if (name == "r32g32_sfloat") return MTLVertexFormatFloat2;
    if (name == "r32g32b32_sfloat") return MTLVertexFormatFloat3;
    if (name == "r32g32b32a32_sfloat") return MTLVertexFormatFloat4;
    if (name == "r32_uint") return MTLVertexFormatUInt;
    if (name == "r32g32_uint") return MTLVertexFormatUInt2;
    if (name == "r32g32b32_uint") return MTLVertexFormatUInt3;
    if (name == "r32g32b32a32_uint") return MTLVertexFormatUInt4;
    if (name == "r32_sint") return MTLVertexFormatInt;
    if (name == "r32g32_sint") return MTLVertexFormatInt2;
    if (name == "r32g32b32_sint") return MTLVertexFormatInt3;
    if (name == "r32g32b32a32_sint") return MTLVertexFormatInt4;
    return MTLVertexFormatInvalid;
}

MTLSamplerAddressMode ToMetalAddressMode(TextureWrap wrap)
{
    switch (wrap) {
    case TextureWrap::CLAMP_TO_EDGE: return MTLSamplerAddressModeClampToEdge;
    case TextureWrap::REPEAT: return MTLSamplerAddressModeRepeat;
    }
    return MTLSamplerAddressModeClampToEdge;
}

MTLSamplerMinMagFilter ToMetalFilter(TextureFilter filter)
{
    switch (filter) {
    case TextureFilter::LINEAR: return MTLSamplerMinMagFilterLinear;
    case TextureFilter::NEAREST: return MTLSamplerMinMagFilterNearest;
    }
    return MTLSamplerMinMagFilterLinear;
}

/// Uncompressed formats only. Block-compressed source images are rejected
/// rather than decoded here: silently expanding them would change memory use
/// and filtering behaviour relative to the compatibility backend.
bool ToMetalImageFormat(TextureFormat format, MTLPixelFormat& out, uint32_t& bytes_per_pixel)
{
    switch (format) {
    case TextureFormat::RGBA8:
        out             = MTLPixelFormatRGBA8Unorm;
        bytes_per_pixel = 4;
        return true;
    case TextureFormat::RG8:
        out             = MTLPixelFormatRG8Unorm;
        bytes_per_pixel = 2;
        return true;
    case TextureFormat::R8:
        out             = MTLPixelFormatR8Unorm;
        bytes_per_pixel = 1;
        return true;
    case TextureFormat::RGB8:
    case TextureFormat::BC1:
    case TextureFormat::BC2:
    case TextureFormat::BC3: return false;
    }
    return false;
}

/// Matrices the Metal backend has to carry through its clip-space fold.
/// `MetalClipSpaceFold` is the identity on every convention pair this renderer
/// has met, but the fold is applied rather than skipped so that a future change
/// to either convention is honoured instead of silently ignored.
bool FoldsOnLeft(std::string_view name)
{
    return name == G_VP || name == G_MVP || name == G_ETVP;
}

bool FoldsOnRight(std::string_view name)
{
    // The inverse of a folded matrix folds on the other side.
    return name == G_MVPI || name == G_ETVPI;
}

} // namespace

bool MetalDeviceAvailable()
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device != nil;
    }
}

struct MetalRender::Impl
{
    // ---- device
    id<MTLDevice>         device { nil };
    id<MTLCommandQueue>   queue { nil };
    CAMetalLayer*         layer { nil };
    dispatch_semaphore_t  inflight { nullptr };
    NSUInteger            frame_slot { 0 };
    bool                  inited { false };
    std::string           last_error;

    // ---- presentation
    id<MTLRenderPipelineState> present_pipeline { nil };
    id<MTLBuffer>              present_vertices { nil };
    id<MTLBuffer>              present_vertices_flipped { nil };
    id<MTLSamplerState>        present_sampler { nil };
    MTLPixelFormat             drawable_format { MTLPixelFormatBGRA8Unorm };

    // ---- host configuration
    uint32_t             output_width { 0 };
    uint32_t             output_height { 0 };
    double               display_scale_factor { 1.0 };
    WallpaperScalingMode scaling_mode { WallpaperScalingMode::NONE };
    double               scaling_factor { 1.0 };
    bool                 horizontal_flip { false };
    bool                 video_paused { false };
    RendererCounters*    counters { nullptr };

    // ---- compiled graph
    struct TextureSlotBinding
    {
        int vertex_texture { -1 };
        int fragment_texture { -1 };
        int vertex_sampler { -1 };
        int fragment_sampler { -1 };

        [[nodiscard]] bool bound() const
        {
            return vertex_texture >= 0 || fragment_texture >= 0;
        }
    };

    struct PreparedPass
    {
        MetalPassKind kind { MetalPassKind::Unsupported };
        std::size_t   description_index { 0 };

        // draw state
        id<MTLRenderPipelineState>         pipeline { nil };
        MetalShaderReflection              reflection;
        int                                vertex_uniform_slot { -1 };
        int                                fragment_uniform_slot { -1 };
        uint32_t                           uniform_size { 0 };
        uint32_t                           uniform_offset { 0 };
        std::vector<TextureSlotBinding>    texture_slots;
        std::vector<id<MTLSamplerState>>   samplers;
        std::vector<id<MTLBuffer>>         vertex_buffers;
        std::vector<NSUInteger>            vertex_buffer_slots;
        id<MTLBuffer>                      index_buffer { nil };
        uint32_t                           index_count { 0 };
        std::vector<SceneMesh::DrawRange>  draw_ranges;
        uint32_t                           vertex_count { 0 };
        /// Empty in this version: the capability gate rejects sprite sheets, so
        /// no pass has an animated frame. Kept because the shared value updater
        /// takes one by reference.
        sprite_map_t                       sprites;
    };

    std::vector<ScenePassDescription>                   descriptions;
    std::vector<PreparedPass>                           prepared;
    std::unordered_map<std::string, id<MTLTexture>>     targets;
    std::unordered_map<std::string, id<MTLTexture>>     images;
    std::unordered_map<std::string, id<MTLSamplerState>> samplers;
    std::unordered_map<std::string, id<MTLLibrary>>     libraries;
    std::unordered_map<MetalPipelineKey, id<MTLRenderPipelineState>, MetalPipelineKeyHash>
                              pipelines;
    std::vector<id<MTLBuffer>> uniform_rings;
    uint32_t                   uniform_ring_size { 0 };
    bool                       graph_ready { false };
    uint32_t                   demand_reasons {
        static_cast<uint32_t>(vulkan::DynamicReason::UnknownInput)
    };

    bool fail(std::string message)
    {
        last_error = std::move(message);
        LOG_ERROR("metal render: %s", last_error.c_str());
        return false;
    }

    void releaseGraph();
    void releasePresentation();

    bool buildPresentation();
    bool compile(Scene& scene, rg::RenderGraph& graph);
    bool prepareTargets(Scene& scene);
    bool prepareDraw(Scene& scene, std::size_t index, PreparedPass& out);
    id<MTLTexture> resolveTexture(Scene& scene, const std::string& key,
                                  id<MTLSamplerState>* sampler_out);
    id<MTLSamplerState> samplerFor(const TextureSample& sample);
    id<MTLRenderPipelineState> pipelineFor(const MetalPipelineKey& key,
                                           const SceneMetalProgram& program,
                                           MTLVertexDescriptor* vertex_descriptor);
    id<MTLLibrary> libraryFor(const SceneMetalStage& stage);
    void computeDemandReasons(Scene& scene, rg::RenderGraph& graph);
    void writeUniforms(Scene& scene, const ScenePassDescription& desc, const PreparedPass& pass,
                       uint8_t* destination);
    WallpaperScalingLayout scalingLayout(const Scene& scene, uint32_t width,
                                         uint32_t height) const;
};

void MetalRender::Impl::releaseGraph()
{
    descriptions.clear();
    prepared.clear();
    targets.clear();
    images.clear();
    samplers.clear();
    libraries.clear();
    pipelines.clear();
    uniform_rings.clear();
    uniform_ring_size = 0;
    graph_ready       = false;
    demand_reasons    = static_cast<uint32_t>(vulkan::DynamicReason::UnknownInput);
}

void MetalRender::Impl::releasePresentation()
{
    present_pipeline         = nil;
    present_vertices         = nil;
    present_vertices_flipped = nil;
    present_sampler          = nil;
    layer                    = nil;
}

bool MetalRender::Impl::buildPresentation()
{
    NSError* error = nil;
    NSString* source =
        [[NSString alloc] initWithBytes:kPresentShaderSource.data()
                                 length:kPresentShaderSource.size()
                               encoding:NSUTF8StringEncoding];
    MTLCompileOptions* options = [MTLCompileOptions new];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (library == nil) {
        return fail(std::string("presentation shader failed to compile: ") +
                    (error != nil ? error.localizedDescription.UTF8String : "unknown error"));
    }

    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction   = [library newFunctionWithName:@"owe_present_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"owe_present_fragment"];
    descriptor.colorAttachments[0].pixelFormat = drawable_format;
    present_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (present_pipeline == nil) {
        return fail(std::string("presentation pipeline failed to build: ") +
                    (error != nil ? error.localizedDescription.UTF8String : "unknown error"));
    }

    present_vertices = [device newBufferWithBytes:kPresentVertices
                                           length:sizeof(kPresentVertices)
                                          options:MTLResourceStorageModeShared];
    present_vertices_flipped = [device newBufferWithBytes:kPresentVerticesFlipped
                                                   length:sizeof(kPresentVerticesFlipped)
                                                  options:MTLResourceStorageModeShared];
    if (present_vertices == nil || present_vertices_flipped == nil) {
        return fail("presentation vertices could not be allocated");
    }

    MTLSamplerDescriptor* sampler_descriptor = [MTLSamplerDescriptor new];
    sampler_descriptor.minFilter    = MTLSamplerMinMagFilterLinear;
    sampler_descriptor.magFilter    = MTLSamplerMinMagFilterLinear;
    sampler_descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    present_sampler = [device newSamplerStateWithDescriptor:sampler_descriptor];
    if (present_sampler == nil) return fail("presentation sampler could not be created");
    return true;
}

id<MTLSamplerState> MetalRender::Impl::samplerFor(const TextureSample& sample)
{
    char key_bytes[5] = {
        static_cast<char>(sample.wrapS),
        static_cast<char>(sample.wrapT),
        static_cast<char>(sample.magFilter),
        static_cast<char>(sample.minFilter),
        '\0',
    };
    const std::string key(key_bytes, 4);
    if (auto found = samplers.find(key); found != samplers.end()) return found->second;

    MTLSamplerDescriptor* descriptor = [MTLSamplerDescriptor new];
    descriptor.sAddressMode = ToMetalAddressMode(sample.wrapS);
    descriptor.tAddressMode = ToMetalAddressMode(sample.wrapT);
    descriptor.magFilter    = ToMetalFilter(sample.magFilter);
    descriptor.minFilter    = ToMetalFilter(sample.minFilter);
    descriptor.mipFilter    = MTLSamplerMipFilterLinear;
    id<MTLSamplerState> state = [device newSamplerStateWithDescriptor:descriptor];
    if (state == nil) return nil;
    samplers.emplace(key, state);
    return state;
}

id<MTLTexture> MetalRender::Impl::resolveTexture(Scene& scene, const std::string& key,
                                                 id<MTLSamplerState>* sampler_out)
{
    if (key.empty()) return nil;

    if (auto target = targets.find(key); target != targets.end()) {
        if (sampler_out != nullptr) {
            const auto* render_target = scene.FindRenderTarget(key);
            *sampler_out = samplerFor(render_target != nullptr ? render_target->sample
                                                               : TextureSample {});
        }
        return target->second;
    }

    if (auto image = images.find(key); image != images.end()) {
        if (sampler_out != nullptr) {
            const auto found = scene.textures.find(key);
            *sampler_out     = samplerFor(found != scene.textures.end() ? found->second.sample
                                                                       : TextureSample {});
        }
        return image->second;
    }

    if (IsSpecTex(key)) {
        // A spec texture with no allocation is a render target the graph never
        // produced. Treated as missing rather than substituted.
        return nil;
    }

    if (scene.imageParser == nullptr) return nil;
    auto parsed = scene.imageParser->Parse(key);
    if (parsed == nullptr || parsed->slots.empty() || parsed->slots.front().mipmaps.empty()) {
        return nil;
    }

    MTLPixelFormat format {};
    uint32_t       bytes_per_pixel = 0;
    if (! ToMetalImageFormat(parsed->header.format, format, bytes_per_pixel)) return nil;

    const auto& slot = parsed->slots.front();
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:(NSUInteger)slot.width
                                                          height:(NSUInteger)slot.height
                                                       mipmapped:slot.mipmaps.size() > 1];
    descriptor.mipmapLevelCount = slot.mipmaps.size();
    descriptor.usage            = MTLTextureUsageShaderRead;
    // Shared storage, so the pixels are written straight into the texture. A
    // staging buffer plus a blit would need the frame to wait on an upload,
    // which is exactly what the per-frame path must never do.
    descriptor.storageMode = MTLStorageModeShared;

    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) return nil;
    for (std::size_t level = 0; level < slot.mipmaps.size(); ++level) {
        const auto& mipmap = slot.mipmaps[level];
        if (mipmap.data == nullptr || mipmap.width <= 0 || mipmap.height <= 0) continue;
        MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)mipmap.width,
                                           (NSUInteger)mipmap.height);
        [texture replaceRegion:region
                   mipmapLevel:level
                     withBytes:mipmap.data.get()
                   bytesPerRow:(NSUInteger)mipmap.width * bytes_per_pixel];
    }

    images.emplace(key, texture);
    if (sampler_out != nullptr) {
        const auto found = scene.textures.find(key);
        *sampler_out     = samplerFor(found != scene.textures.end() ? found->second.sample
                                                                   : parsed->header.sample);
    }
    return texture;
}

id<MTLLibrary> MetalRender::Impl::libraryFor(const SceneMetalStage& stage)
{
    if (auto found = libraries.find(stage.source); found != libraries.end()) return found->second;

    NSError*  error = nil;
    NSString* source = [[NSString alloc] initWithBytes:stage.source.data()
                                                length:stage.source.size()
                                              encoding:NSUTF8StringEncoding];
    MTLCompileOptions* options = [MTLCompileOptions new];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (library == nil) {
        last_error = std::string("a shader could not be compiled by Metal: ") +
                     (error != nil ? error.localizedDescription.UTF8String : "unknown error");
        return nil;
    }
    libraries.emplace(stage.source, library);
    return library;
}

id<MTLRenderPipelineState> MetalRender::Impl::pipelineFor(const MetalPipelineKey& key,
                                                          const SceneMetalProgram& program,
                                                          MTLVertexDescriptor* vertex_descriptor)
{
    if (auto found = pipelines.find(key); found != pipelines.end()) return found->second;

    id<MTLFunction> vertex_function   = nil;
    id<MTLFunction> fragment_function = nil;
    for (const auto& stage : program.stages) {
        id<MTLLibrary> library = libraryFor(stage);
        if (library == nil) return nil;
        NSString* name = [NSString stringWithUTF8String:stage.entry_point.c_str()];
        id<MTLFunction> function = [library newFunctionWithName:name];
        if (function == nil) {
            last_error = "a translated shader has no entry point named " + stage.entry_point;
            return nil;
        }
        if (stage.kind == SceneMetalStageKind::Vertex) {
            vertex_function = function;
        } else {
            fragment_function = function;
        }
    }
    if (vertex_function == nil || fragment_function == nil) {
        last_error = "a translated shader is missing a stage";
        return nil;
    }

    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction               = vertex_function;
    descriptor.fragmentFunction             = fragment_function;
    descriptor.vertexDescriptor             = vertex_descriptor;
    descriptor.rasterSampleCount            = key.sample_count;
    descriptor.alphaToCoverageEnabled       = key.blend.alpha_to_coverage;

    MTLRenderPipelineColorAttachmentDescriptor* attachment = descriptor.colorAttachments[0];
    attachment.pixelFormat = static_cast<MTLPixelFormat>(key.color_format);
    attachment.writeMask   = key.write_alpha ? MTLColorWriteMaskAll
                                             : (MTLColorWriteMaskRed | MTLColorWriteMaskGreen |
                                                MTLColorWriteMaskBlue);
    attachment.blendingEnabled = key.blend.blending_enabled;
    if (key.blend.blending_enabled) {
        attachment.rgbBlendOperation =
            static_cast<MTLBlendOperation>(key.blend.rgb_operation);
        attachment.alphaBlendOperation =
            static_cast<MTLBlendOperation>(key.blend.alpha_operation);
        attachment.sourceRGBBlendFactor =
            static_cast<MTLBlendFactor>(key.blend.source_rgb);
        attachment.destinationRGBBlendFactor =
            static_cast<MTLBlendFactor>(key.blend.destination_rgb);
        attachment.sourceAlphaBlendFactor =
            static_cast<MTLBlendFactor>(key.blend.source_alpha);
        attachment.destinationAlphaBlendFactor =
            static_cast<MTLBlendFactor>(key.blend.destination_alpha);
    }

    NSError* error = nil;
    id<MTLRenderPipelineState> state =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (state == nil) {
        last_error = std::string("a shader pipeline could not be created: ") +
                     (error != nil ? error.localizedDescription.UTF8String : "unknown error");
        return nil;
    }
    pipelines.emplace(key, state);
    return state;
}

bool MetalRender::Impl::prepareTargets(Scene& scene)
{
    targets.clear();
    for (const auto& [name, target] : scene.renderTargets) {
        if (target.width <= 0 || target.height <= 0) continue;
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:(NSUInteger)target.width
                                        height:(NSUInteger)target.height
                                     mipmapped:NO];
        descriptor.usage = kRenderTargetUsage;
        // Private, never memoryless. A later pass, the presentation blit and a
        // poster capture all read these after the pass that wrote them has
        // ended, so their contents have to survive the render pass.
        descriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture == nil) {
            return fail("a render target could not be allocated");
        }
        texture.label = [NSString stringWithUTF8String:name.c_str()];
        targets.emplace(name, texture);
    }
    if (targets.find(scene.ResolveRenderTargetName(SpecTex_Default)) == targets.end()) {
        return fail("the scene has no output image");
    }
    return true;
}

bool MetalRender::Impl::prepareDraw(Scene& scene, std::size_t index, PreparedPass& out)
{
    const auto& desc = descriptions[index];
    auto*       mesh = desc.node->Mesh();
    if (mesh == nullptr) return fail("a draw step lost its mesh");
    if (desc.submesh_index >= mesh->Submeshes().size()) {
        return fail("a draw step names a submesh that does not exist");
    }
    const auto& submesh  = mesh->Submeshes()[desc.submesh_index];
    const auto* material = mesh->MaterialForSlot(desc.material_slot);
    if (material == nullptr || material->customShader.shader == nullptr) {
        return fail("a draw step lost its material");
    }
    const auto* program = material->customShader.shader->metal_program.get();
    if (program == nullptr || ! program->ok()) {
        return fail("a shader could not be translated to Metal");
    }

    std::string reflection_error;
    if (! ParseMetalShaderReflection(program->reflection_json, out.reflection, &reflection_error)) {
        return fail(reflection_error);
    }

    // ---- resource slots, matched on the original GLSL names.
    out.texture_slots.assign(desc.texture_keys.size(), TextureSlotBinding {});
    out.samplers.assign(desc.texture_keys.size(), nil);
    const auto* uniform_block = out.reflection.uniformBlock();
    out.uniform_size          = uniform_block != nullptr ? uniform_block->size : 0;

    for (const auto& stage : program->stages) {
        const bool vertex_stage = stage.kind == SceneMetalStageKind::Vertex;
        for (const auto& binding : stage.bindings) {
            if (binding.set != 0) {
                return fail("a shader binds a resource outside descriptor set 0");
            }
            if (uniform_block != nullptr && binding.name == uniform_block->name) {
                if (binding.slot_kind != SceneMetalSlotKind::Buffer) {
                    return fail("a shader binds its uniform block as something other than a "
                                "buffer");
                }
                (vertex_stage ? out.vertex_uniform_slot : out.fragment_uniform_slot) =
                    static_cast<int>(binding.slot);
                continue;
            }
            const auto texture_slot = vulkan::detail::CustomShaderTextureSlot(binding.name);
            if (texture_slot.has_value()) {
                if (*texture_slot >= out.texture_slots.size()) {
                    return fail("a shader samples a texture slot the material does not have");
                }
                auto& slot = out.texture_slots[*texture_slot];
                if (binding.slot_kind == SceneMetalSlotKind::Texture) {
                    (vertex_stage ? slot.vertex_texture : slot.fragment_texture) =
                        static_cast<int>(binding.slot);
                } else if (binding.slot_kind == SceneMetalSlotKind::Sampler) {
                    (vertex_stage ? slot.vertex_sampler : slot.fragment_sampler) =
                        static_cast<int>(binding.slot);
                } else {
                    return fail("a shader binds a texture as a buffer");
                }
                continue;
            }
            const auto sampler_slot = vulkan::detail::CustomShaderSamplerSlot(binding.name);
            if (sampler_slot.has_value()) {
                if (*sampler_slot >= out.texture_slots.size()) {
                    return fail("a shader samples a texture slot the material does not have");
                }
                auto& slot = out.texture_slots[*sampler_slot];
                (vertex_stage ? slot.vertex_sampler : slot.fragment_sampler) =
                    static_cast<int>(binding.slot);
                continue;
            }
            return fail("a shader binds a resource the native renderer does not recognise: " +
                        binding.name);
        }
    }

    // ---- textures
    for (std::size_t i = 0; i < desc.texture_keys.size(); ++i) {
        if (! out.texture_slots[i].bound()) continue;
        id<MTLSamplerState> sampler = nil;
        id<MTLTexture> texture = resolveTexture(scene, desc.texture_keys[i], &sampler);
        if (texture == nil) {
            return fail("an image a layer needs could not be loaded: " + desc.texture_keys[i]);
        }
        out.samplers[i] = sampler;
    }

    // ---- vertex layout
    MTLVertexDescriptor* vertex_descriptor = [MTLVertexDescriptor new];
    uint64_t             layout_id         = 0xcbf29ce484222325ULL;
    out.vertex_buffers.clear();
    out.vertex_buffer_slots.clear();
    out.vertex_count = 0;
    if (submesh.VertexCount() == 0) return fail("a draw step has no vertices");
    if (submesh.VertexCount() > kVertexBufferTopIndex) {
        return fail("a draw step needs more vertex buffers than Metal can bind");
    }

    std::vector<Map<std::string, SceneVertexArray::SceneVertexAttributeOffset>> attribute_maps;
    attribute_maps.reserve(submesh.VertexCount());
    for (std::size_t i = 0; i < submesh.VertexCount(); ++i) {
        const auto&     vertex = submesh.GetVertexArray(i);
        const NSUInteger slot  = kVertexBufferTopIndex - i;
        attribute_maps.push_back(vertex.GetAttrOffsetMap());

        if (vertex.DataSizeOf() == 0) return fail("a draw step has an empty vertex buffer");
        id<MTLBuffer> buffer = [device newBufferWithBytes:vertex.Data()
                                                   length:vertex.DataSizeOf()
                                                  options:MTLResourceStorageModeShared];
        if (buffer == nil) return fail("a vertex buffer could not be allocated");
        out.vertex_buffers.push_back(buffer);
        out.vertex_buffer_slots.push_back(slot);

        vertex_descriptor.layouts[slot].stride       = vertex.OneSizeOf();
        vertex_descriptor.layouts[slot].stepFunction = MTLVertexStepFunctionPerVertex;
        vertex_descriptor.layouts[slot].stepRate     = 1;
        layout_id = layout_id * 1099511628211ULL + vertex.OneSizeOf();
        out.vertex_count += static_cast<uint32_t>(vertex.DataSize() / vertex.OneSize());
    }

    for (const auto& input : out.reflection.inputs) {
        const auto format = ToMetalVertexFormat(input.format);
        if (format == MTLVertexFormatInvalid) {
            return fail("a shader uses a vertex format the native renderer does not recognise: " +
                        input.format);
        }
        // The buffer that actually carries this attribute, falling back to the
        // first one exactly as the compatibility backend does when a shader
        // declares an input the mesh does not provide.
        std::size_t source = 0;
        std::size_t offset = 0;
        for (std::size_t i = 0; i < attribute_maps.size(); ++i) {
            const auto found = attribute_maps[i].find(input.name);
            if (found == attribute_maps[i].end()) continue;
            source = i;
            offset = found->second.offset;
            break;
        }
        vertex_descriptor.attributes[input.location].format      = format;
        vertex_descriptor.attributes[input.location].offset      = offset;
        vertex_descriptor.attributes[input.location].bufferIndex =
            out.vertex_buffer_slots[source];
        layout_id = layout_id * 1099511628211ULL + (input.location * 31 + offset);
    }

    // A resource slot that collides with a vertex buffer slot would silently
    // overwrite one with the other.
    for (const auto slot : out.vertex_buffer_slots) {
        if (out.vertex_uniform_slot >= 0 &&
            static_cast<NSUInteger>(out.vertex_uniform_slot) == slot) {
            return fail("a shader binds a uniform block where a vertex buffer has to go");
        }
    }

    // ---- indices
    if (submesh.IndexCount() > 0) {
        const auto& indices = submesh.GetIndexArray(0);
        // The engine packs 16-bit indices into a 32-bit array, which is why the
        // compatibility backend binds them as UINT16 over two thirds of the
        // element count.
        const std::size_t count = (indices.DataCount() * 2) / 3;
        out.index_count         = static_cast<uint32_t>(count * 3);
        out.draw_ranges         = submesh.DrawRanges();
        if (out.index_count > 0) {
            out.index_buffer = [device newBufferWithBytes:indices.Data()
                                                    length:out.index_count * sizeof(uint16_t)
                                                   options:MTLResourceStorageModeShared];
            if (out.index_buffer == nil) return fail("an index buffer could not be allocated");
        }
    }

    // ---- pipeline
    const auto  target = targets.find(desc.target_key);
    if (target == targets.end()) return fail("a draw step targets an image that does not exist");

    MetalPipelineKey key {
        .program_id       = reinterpret_cast<uint64_t>(program),
        .vertex_layout_id = layout_id,
        .blend            = ToMetalBlendState(desc.blend),
        .color_format     = static_cast<MetalPixelFormat>(target->second.pixelFormat),
        .sample_count     = 1,
        .write_alpha      = desc.write_alpha,
    };
    out.pipeline = pipelineFor(key, *program, vertex_descriptor);
    if (out.pipeline == nil) return fail(last_error.empty() ? "a shader pipeline could not be "
                                                             "created"
                                                            : last_error);

    // ---- uniform initial state
    auto* updater = scene.shaderValueUpdater.get();
    if (updater != nullptr) {
        auto exists_op = [&out](std::string_view name) { return out.reflection.hasMember(name); };
        updater->InitUniforms(desc.node, desc.material_slot, exists_op);
    }
    return true;
}

void MetalRender::Impl::writeUniforms(Scene& scene, const ScenePassDescription& desc,
                                      const PreparedPass& pass, uint8_t* destination)
{
    const auto* block = pass.reflection.uniformBlock();
    if (block == nullptr || destination == nullptr) return;

    const auto write = [&](std::string_view name, const ShaderValue& value) {
        const auto* member = pass.reflection.member(name);
        if (member == nullptr) return;

        // The fold is applied to every matrix that carries clip space, so a
        // change to either API's convention is honoured rather than ignored.
        std::array<float, 16> folded {};
        const float*          data  = value.data();
        std::size_t           count = value.size();
        if (count == 16 && (FoldsOnLeft(name) || FoldsOnRight(name))) {
            Eigen::Matrix4f matrix = Eigen::Map<const Eigen::Matrix4f>(value.data());
            const Eigen::Matrix4f fold = MetalClipSpaceFold().cast<float>();
            matrix                     = FoldsOnLeft(name) ? (fold * matrix).eval()
                                                           : (matrix * fold).eval();
            std::memcpy(folded.data(), matrix.data(), sizeof(folded));
            data = folded.data();
        }

        const std::size_t bytes = count * sizeof(float);
        if (member->array_count > 0 && member->array_stride > 0 &&
            bytes % member->array_count == 0) {
            const std::size_t element_size = bytes / member->array_count;
            if (element_size > 0 && element_size <= member->array_stride) {
                for (std::size_t i = 0; i < member->array_count; ++i) {
                    const std::size_t at = member->offset + i * member->array_stride;
                    if (at + element_size > block->size) return;
                    std::memcpy(destination + at,
                                reinterpret_cast<const uint8_t*>(data) + i * element_size,
                                element_size);
                }
                return;
            }
        }
        const std::size_t copy = std::min<std::size_t>(bytes, block->size - member->offset);
        if (member->offset >= block->size) return;
        std::memcpy(destination + member->offset, data, copy);
    };

    auto* material = desc.node != nullptr && desc.node->Mesh() != nullptr
                         ? desc.node->Mesh()->MaterialForSlot(desc.material_slot)
                         : nullptr;
    if (material == nullptr) return;

    // Defaults first, then the author's constants, then this frame's values, so
    // a value that is both defaulted and animated ends up animated.
    if (material->customShader.shader != nullptr) {
        for (const auto& [name, value] : material->customShader.shader->default_uniforms) {
            write(name, value);
        }
    }
    for (const auto& [name, value] : material->customShader.constValues) write(name, value);

    auto* updater = scene.shaderValueUpdater.get();
    if (updater == nullptr) return;

    std::string original_camera;
    bool        restore_camera = false;
    if (! desc.camera_override.empty() && desc.node->Camera() != desc.camera_override) {
        original_camera = desc.node->Camera();
        desc.node->SetCamera(desc.camera_override);
        restore_camera = true;
    }
    auto& sprites = const_cast<PreparedPass&>(pass).sprites;
    updater->UpdateUniforms(desc.node, desc.material_slot, sprites, write);
    if (restore_camera) desc.node->SetCamera(original_camera);
}

void MetalRender::Impl::computeDemandReasons(Scene& scene, rg::RenderGraph& graph)
{
    (void)graph;
    // Derived from this backend's OWN pass descriptions, not from the render
    // graph's Vulkan pass objects. The Metal path never instantiates those, so
    // walking the graph found nothing, concluded nothing was dynamic, and
    // reported a provably-still scene — which would let on-demand updating stop
    // the clock on an animating wallpaper. An empty answer is the dangerous
    // answer here, so every path that cannot account for a pass adds
    // `UnknownInput` instead of contributing silence.
    uint32_t reasons              = 0;
    bool     saw_shader_pass      = false;
    bool     understood_every_pass = true;

    const auto* updater       = scene.shaderValueUpdater.get();
    const auto* runtime_images =
        dynamic_cast<const RuntimeImageSource*>(scene.imageParser.get());

    for (const auto& desc : descriptions) {
        switch (desc.kind) {
        case MetalPassKind::CustomShader: {
            saw_shader_pass = true;
            // Reflection captured at InitUniforms, never a search of shader
            // text. A material with no updater reports every kind, so an
            // untracked pass cannot look still by omission.
            const uint32_t varying =
                updater != nullptr
                    ? updater->FrameVaryingUniforms(desc.node, desc.material_slot)
                    : frame_varying_uniform::kAll;
            if ((varying & (frame_varying_uniform::kTime | frame_varying_uniform::kDayTime)) != 0)
                reasons |= vulkan::DynamicReason::TimeUniform;
            if ((varying & frame_varying_uniform::kAudio) != 0)
                reasons |= vulkan::DynamicReason::AudioUniform;
            if ((varying & (frame_varying_uniform::kPointer | frame_varying_uniform::kParallax)) !=
                0)
                reasons |= vulkan::DynamicReason::PointerUniform;
            if ((varying & frame_varying_uniform::kBones) != 0)
                reasons |= vulkan::DynamicReason::BoneUniform;

            if (runtime_images != nullptr) {
                for (const auto& texture : desc.texture_keys) {
                    if (texture.empty()) continue;
                    if (runtime_images->IsRuntimeImage(texture)) {
                        reasons |= vulkan::DynamicReason::RuntimeImage;
                        break;
                    }
                }
            }
            break;
        }
        case MetalPassKind::Copy:
        case MetalPassKind::Clear:
        case MetalPassKind::Virtual: break;
        case MetalPassKind::Unsupported: understood_every_pass = false; break;
        }
    }

    // A compiled graph that yielded no shader pass is not a still scene; it is
    // a graph this analysis did not understand.
    if (! saw_shader_pass || ! understood_every_pass) {
        reasons |= vulkan::DynamicReason::UnknownInput;
    }
    demand_reasons = reasons;
}

bool MetalRender::Impl::compile(Scene& scene, rg::RenderGraph& graph)
{
    releaseGraph();

    if (auto reason = MetalGraphRejection(scene, graph); ! reason.empty()) {
        return fail(std::move(reason));
    }

    const MTLSize drawable_extent { std::max<uint32_t>(1, output_width),
                                    std::max<uint32_t>(1, output_height), 1 };
    vulkan::ResolveScreenBoundRenderTargetSizes(
        scene,
        VkExtent2D { static_cast<uint32_t>(drawable_extent.width),
                     static_cast<uint32_t>(drawable_extent.height) });

    if (! prepareTargets(scene)) return false;

    std::string error;
    if (! BuildScenePassDescriptions(scene, graph, descriptions, &error)) {
        return fail(std::move(error));
    }

    prepared.resize(descriptions.size());
    uint32_t uniform_cursor = 0;
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        auto& pass            = prepared[i];
        pass.kind             = descriptions[i].kind;
        pass.description_index = i;
        if (pass.kind != MetalPassKind::CustomShader) continue;
        if (! prepareDraw(scene, i, pass)) return false;
        if (pass.uniform_size > 0) {
            // Metal requires a 256-byte aligned buffer offset for constant
            // buffers on macOS.
            uniform_cursor       = (uniform_cursor + 255u) & ~255u;
            pass.uniform_offset  = uniform_cursor;
            uniform_cursor      += pass.uniform_size;
        }
    }

    uniform_ring_size = std::max<uint32_t>(uniform_cursor, 256u);
    uniform_rings.clear();
    for (NSUInteger i = 0; i < kFramesInFlight; ++i) {
        id<MTLBuffer> buffer = [device newBufferWithLength:uniform_ring_size
                                                   options:MTLResourceStorageModeShared];
        if (buffer == nil) return fail("uniform storage could not be allocated");
        uniform_rings.push_back(buffer);
    }

    if (scene.shaderValueUpdater != nullptr) {
        const auto* output = scene.FindRenderTarget(SpecTex_Default);
        const auto  width  = output != nullptr ? std::max(1, output->width) : 1;
        const auto  height = output != nullptr ? std::max(1, output->height) : 1;
        scene.shaderValueUpdater->SetScreenSize(width, height);
        scene.shaderValueUpdater->SetTexelSize(1.0f / static_cast<float>(width),
                                               1.0f / static_cast<float>(height));
    }

    computeDemandReasons(scene, graph);
    graph_ready = true;
    last_error.clear();
    return true;
}

WallpaperScalingLayout MetalRender::Impl::scalingLayout(const Scene& scene, uint32_t width,
                                                        uint32_t height) const
{
    const double scale_factor = NormalizeScaleFactor(display_scale_factor);
    const auto   source_extent =
        vulkan::ResolveSceneSourceExtent(scene, { std::max(1u, width), std::max(1u, height) });
    const uint32_t logical_width = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(width) / scale_factor)));
    const uint32_t logical_height = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(height) / scale_factor)));
    return ComputeWallpaperScalingLayout(scaling_mode, source_extent.width, source_extent.height,
                                         logical_width, logical_height, scale_factor,
                                         scaling_factor);
}

// ---------------------------------------------------------------------------

MetalRender::MetalRender(): pImpl(std::make_unique<Impl>()) {}
MetalRender::~MetalRender() { destroy(); }

bool MetalRender::init(const MetalRenderInitInfo& info)
{
    @autoreleasepool {
        if (info.metal_layer == nullptr) return pImpl->fail("no Metal layer was provided");
        CAMetalLayer* layer = (__bridge CAMetalLayer*)info.metal_layer;
        if (! [layer isKindOfClass:[CAMetalLayer class]]) {
            return pImpl->fail("the wallpaper window has no Metal layer");
        }

        id<MTLDevice> device = layer.device;
        if (device == nil) {
            device = MTLCreateSystemDefaultDevice();
            if (device == nil) return pImpl->fail("this machine has no Metal device");
            layer.device = device;
        }

        pImpl->device = device;
        pImpl->layer  = layer;
        pImpl->queue  = [device newCommandQueue];
        if (pImpl->queue == nil) return pImpl->fail("a Metal command queue could not be created");

        pImpl->drawable_format = layer.pixelFormat != MTLPixelFormatInvalid
                                     ? layer.pixelFormat
                                     : MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly  = YES;
        pImpl->output_width    = info.width;
        pImpl->output_height   = info.height;
        pImpl->display_scale_factor = NormalizeScaleFactor(info.display_scale_factor);
        if (pImpl->inflight == nullptr) {
            pImpl->inflight = dispatch_semaphore_create(kFramesInFlight);
        }
        if (! pImpl->buildPresentation()) return false;
        pImpl->inited = true;
        pImpl->last_error.clear();
        return true;
    }
}

void MetalRender::destroy()
{
    if (pImpl == nullptr) return;
    @autoreleasepool {
        // The only synchronous wait in this class. Destruction has to observe
        // that no frame is still reading the textures about to be released, and
        // there is no later point at which to notice.
        if (pImpl->queue != nil && pImpl->inflight != nullptr && pImpl->inited) {
            id<MTLCommandBuffer> drain = [pImpl->queue commandBuffer];
            [drain commit];
            [drain waitUntilCompleted];
        }
        pImpl->releaseGraph();
        pImpl->releasePresentation();
        pImpl->queue  = nil;
        pImpl->device = nil;
        pImpl->inited = false;
    }
}

bool MetalRender::inited() const { return pImpl->inited; }

bool MetalRender::releaseSurface()
{
    @autoreleasepool {
        pImpl->releasePresentation();
        pImpl->inited = false;
        return true;
    }
}

bool MetalRender::resetSurface(const MetalRenderInitInfo& info)
{
    // Keeps the compiled graph: only presentation-scoped state is rebuilt.
    const bool had_graph = pImpl->graph_ready;
    @autoreleasepool {
        if (info.metal_layer == nullptr) return pImpl->fail("no Metal layer was provided");
        CAMetalLayer* layer = (__bridge CAMetalLayer*)info.metal_layer;
        if (! [layer isKindOfClass:[CAMetalLayer class]]) {
            return pImpl->fail("the wallpaper window has no Metal layer");
        }
        if (layer.device == nil) layer.device = pImpl->device;
        pImpl->layer           = layer;
        pImpl->drawable_format = layer.pixelFormat != MTLPixelFormatInvalid
                                     ? layer.pixelFormat
                                     : MTLPixelFormatBGRA8Unorm;
        pImpl->output_width         = info.width;
        pImpl->output_height        = info.height;
        pImpl->display_scale_factor = NormalizeScaleFactor(info.display_scale_factor);
        if (! pImpl->buildPresentation()) return false;
        pImpl->inited     = true;
        pImpl->graph_ready = had_graph;
        return true;
    }
}

bool MetalRender::clearLastRenderGraph()
{
    @autoreleasepool {
        pImpl->releaseGraph();
        return true;
    }
}

bool MetalRender::compileRenderGraph(Scene& scene, rg::RenderGraph& graph)
{
    if (! pImpl->inited) return pImpl->fail("the native renderer is not initialised");
    @autoreleasepool {
        return pImpl->compile(scene, graph);
    }
}

bool MetalRender::ApplyRenderScale(Scene& scene, rg::RenderGraph& graph, double scale)
{
    scene.render_scale = scale;
    @autoreleasepool {
        return pImpl->compile(scene, graph);
    }
}

void MetalRender::UpdateCameraFillMode(Scene& scene, FillMode fillmode)
{
    vulkan::ApplyCameraFillMode(scene, fillmode, pImpl->output_width, pImpl->output_height);
}

void MetalRender::SetWallpaperScalingMode(WallpaperScalingMode mode) { pImpl->scaling_mode = mode; }

void MetalRender::SetWallpaperScalingFactor(double factor)
{
    pImpl->scaling_factor = NormalizeScaleFactor(factor);
}

void MetalRender::SetWallpaperHorizontalFlip(bool enabled) { pImpl->horizontal_flip = enabled; }

void MetalRender::SetVideoPlaybackPaused(bool paused) { pImpl->video_paused = paused; }

void MetalRender::SetVideoPlaybackRate(float) {}

double MetalRender::ShortestVideoFramePeriod() const { return 0.0; }

uint32_t MetalRender::ShaderUpdateDemandReasons() const { return pImpl->demand_reasons; }

void MetalRender::SetCounters(RendererCounters* counters) { pImpl->counters = counters; }

WallpaperCursorMapping MetalRender::CursorMapping(const Scene& scene) const
{
    if (! pImpl->inited) return {};
    if (pImpl->output_width == 0 || pImpl->output_height == 0) return {};
    const auto camera = scene.cameras.find("global");
    if (camera == scene.cameras.end() || camera->second == nullptr) return {};
    const auto position = camera->second->GetPosition();
    return ComputeWallpaperCursorMapping(
        pImpl->scalingLayout(scene, pImpl->output_width, pImpl->output_height),
        position.x(), position.y(), camera->second->Width(), camera->second->Height());
}

const std::string& MetalRender::lastError() const { return pImpl->last_error; }

bool MetalRender::drawFrame(Scene& scene)
{
    if (! pImpl->inited || ! pImpl->graph_ready || pImpl->layer == nil) return false;

    @autoreleasepool {
        auto& impl = *pImpl;

        // Bounds how far the CPU may run ahead. Released by the completion
        // handler below, never by waiting on the command buffer.
        dispatch_semaphore_wait(impl.inflight, DISPATCH_TIME_FOREVER);

        id<CAMetalDrawable> drawable = [impl.layer nextDrawable];
        if (drawable == nil) {
            // The layer has no drawable to give right now. Nothing was
            // submitted, so nothing will signal; release the slot here.
            dispatch_semaphore_signal(impl.inflight);
            return true;
        }

        id<MTLBuffer> uniforms = impl.uniform_rings[impl.frame_slot];
        auto*         uniform_base = static_cast<uint8_t*>(uniforms.contents);

        if (scene.shaderValueUpdater != nullptr) scene.shaderValueUpdater->FrameBegin();
        for (std::size_t i = 0; i < impl.prepared.size(); ++i) {
            auto&       pass = impl.prepared[i];
            const auto& desc = impl.descriptions[i];
            if (pass.kind != MetalPassKind::CustomShader || pass.uniform_size == 0) continue;
            impl.writeUniforms(scene, desc, pass, uniform_base + pass.uniform_offset);
        }
        if (scene.shaderValueUpdater != nullptr) scene.shaderValueUpdater->FrameEnd();

        id<MTLCommandBuffer> command = [impl.queue commandBuffer];

        for (std::size_t i = 0; i < impl.prepared.size(); ++i) {
            const auto& pass = impl.prepared[i];
            const auto& desc = impl.descriptions[i];
            const auto  target = impl.targets.find(desc.target_key);
            if (target == impl.targets.end()) continue;

            if (pass.kind == MetalPassKind::Copy) {
                const auto source = impl.targets.find(desc.source_key);
                if (source == impl.targets.end()) continue;
                id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                if (source->second.width == target->second.width &&
                    source->second.height == target->second.height &&
                    source->second.pixelFormat == target->second.pixelFormat) {
                    [blit copyFromTexture:source->second
                              sourceSlice:0
                              sourceLevel:0
                                toTexture:target->second
                         destinationSlice:0
                         destinationLevel:0
                               sliceCount:1
                               levelCount:1];
                }
                [blit endEncoding];
                continue;
            }

            MTLRenderPassDescriptor* pass_descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
            pass_descriptor.colorAttachments[0].texture = target->second;
            pass_descriptor.colorAttachments[0].loadAction =
                static_cast<MTLLoadAction>(desc.load_action);
            // Always stored: a later pass, the presentation blit or a poster
            // capture reads this target after the pass ends.
            pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass_descriptor.colorAttachments[0].clearColor  = MTLClearColorMake(
                desc.clear_color[0], desc.clear_color[1], desc.clear_color[2],
                desc.clear_color[3]);

            id<MTLRenderCommandEncoder> encoder =
                [command renderCommandEncoderWithDescriptor:pass_descriptor];
            if (pass.kind == MetalPassKind::Clear || pass.pipeline == nil) {
                [encoder endEncoding];
                continue;
            }
            if (desc.visibility_node != nullptr && ! desc.visibility_node->EffectiveVisible()) {
                [encoder endEncoding];
                continue;
            }

            [encoder setViewport:(MTLViewport) { 0.0, 0.0, (double)desc.target_width,
                                                 (double)desc.target_height, 0.0, 1.0 }];
            [encoder setScissorRect:(MTLScissorRect) { 0, 0, desc.target_width,
                                                       desc.target_height }];
            // Folding the clip-space transform into the projection also decides
            // triangle winding, so the cull mode has to be the one the
            // compatibility backend uses -- it renders with VK_CULL_MODE_NONE.
            // Enabling back-face culling here would silently drop half of every
            // scene the moment the fold stops being the identity.
            [encoder setCullMode:static_cast<MTLCullMode>(kSceneCullMode)];
            [encoder setRenderPipelineState:pass.pipeline];

            for (std::size_t v = 0; v < pass.vertex_buffers.size(); ++v) {
                [encoder setVertexBuffer:pass.vertex_buffers[v]
                                  offset:0
                                 atIndex:pass.vertex_buffer_slots[v]];
            }
            if (pass.uniform_size > 0) {
                if (pass.vertex_uniform_slot >= 0) {
                    [encoder setVertexBuffer:uniforms
                                      offset:pass.uniform_offset
                                     atIndex:(NSUInteger)pass.vertex_uniform_slot];
                }
                if (pass.fragment_uniform_slot >= 0) {
                    [encoder setFragmentBuffer:uniforms
                                        offset:pass.uniform_offset
                                       atIndex:(NSUInteger)pass.fragment_uniform_slot];
                }
            }
            for (std::size_t t = 0; t < pass.texture_slots.size(); ++t) {
                const auto& slot = pass.texture_slots[t];
                if (! slot.bound()) continue;
                id<MTLTexture> texture = impl.resolveTexture(scene, desc.texture_keys[t], nullptr);
                if (texture == nil) continue;
                if (slot.vertex_texture >= 0) {
                    [encoder setVertexTexture:texture atIndex:(NSUInteger)slot.vertex_texture];
                }
                if (slot.fragment_texture >= 0) {
                    [encoder setFragmentTexture:texture atIndex:(NSUInteger)slot.fragment_texture];
                }
                if (pass.samplers[t] != nil) {
                    if (slot.vertex_sampler >= 0) {
                        [encoder setVertexSamplerState:pass.samplers[t]
                                               atIndex:(NSUInteger)slot.vertex_sampler];
                    }
                    if (slot.fragment_sampler >= 0) {
                        [encoder setFragmentSamplerState:pass.samplers[t]
                                                 atIndex:(NSUInteger)slot.fragment_sampler];
                    }
                }
            }

            if (pass.index_buffer != nil && pass.index_count > 0) {
                if (! pass.draw_ranges.empty()) {
                    for (const auto& range : pass.draw_ranges) {
                        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                            indexCount:range.indexCount
                                             indexType:MTLIndexTypeUInt16
                                           indexBuffer:pass.index_buffer
                                     indexBufferOffset:range.indexOffset * sizeof(uint16_t)];
                    }
                } else {
                    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:pass.index_count
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:pass.index_buffer
                                 indexBufferOffset:0];
                }
            } else if (pass.vertex_count > 0) {
                [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                            vertexStart:0
                            vertexCount:pass.vertex_count];
            }
            [encoder endEncoding];
        }

        // ---- presentation
        const auto output = impl.targets.find(scene.ResolveRenderTargetName(SpecTex_Default));
        if (output != impl.targets.end()) {
            const auto layout = impl.scalingLayout(scene, (uint32_t)drawable.texture.width,
                                                   (uint32_t)drawable.texture.height);
            MTLRenderPassDescriptor* present = [MTLRenderPassDescriptor renderPassDescriptor];
            present.colorAttachments[0].texture     = drawable.texture;
            present.colorAttachments[0].loadAction  = MTLLoadActionClear;
            present.colorAttachments[0].storeAction = MTLStoreActionStore;
            present.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

            id<MTLRenderCommandEncoder> encoder =
                [command renderCommandEncoderWithDescriptor:present];
            const VulkanViewportBox viewport {
                .x      = (double)layout.viewport_px.x,
                .y      = (double)(layout.viewport_px.y + std::max(1, layout.viewport_px.height)),
                .width  = (double)std::max(1, layout.viewport_px.width),
                .height = -(double)std::max(1, layout.viewport_px.height),
            };
            const auto metal_viewport = ToMetalViewport(viewport);
            [encoder setViewport:(MTLViewport) { metal_viewport.origin_x, metal_viewport.origin_y,
                                                 metal_viewport.width, metal_viewport.height, 0.0,
                                                 1.0 }];
            const NSUInteger scissor_width = (NSUInteger)std::max(0, layout.scissor_px.width);
            const NSUInteger scissor_height = (NSUInteger)std::max(0, layout.scissor_px.height);
            [encoder setScissorRect:(MTLScissorRect) {
                                        (NSUInteger)std::max(0, layout.scissor_px.x),
                                        (NSUInteger)std::max(0, layout.scissor_px.y),
                                        std::min(scissor_width, drawable.texture.width),
                                        std::min(scissor_height, drawable.texture.height) }];
            [encoder setCullMode:static_cast<MTLCullMode>(kSceneCullMode)];
            [encoder setRenderPipelineState:impl.present_pipeline];
            [encoder setVertexBuffer:(impl.horizontal_flip ? impl.present_vertices_flipped
                                                           : impl.present_vertices)
                              offset:0
                             atIndex:0];
            [encoder setFragmentTexture:output->second atIndex:0];
            [encoder setFragmentSamplerState:impl.present_sampler atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [encoder endEncoding];
        }

        dispatch_semaphore_t semaphore = impl.inflight;
        [command addCompletedHandler:^(id<MTLCommandBuffer>) {
          dispatch_semaphore_signal(semaphore);
        }];
        [command presentDrawable:drawable];
        [command commit];

        impl.frame_slot = (impl.frame_slot + 1) % kFramesInFlight;
        if (impl.counters != nullptr) impl.counters->Add(OWE_RC_PRESENT_REQUESTS);
        scene.first_frame_ok = true;
        return true;
    }
}


#ifdef WESCENE_BUILD_TESTS
bool MetalRender::ReadRenderTargetForTests(const std::string& key, std::vector<uint8_t>& rgba,
                                           uint32_t& width, uint32_t& height)
{
    @autoreleasepool {
        const auto found = pImpl->targets.find(key);
        if (found == pImpl->targets.end()) return false;
        id<MTLTexture> texture = found->second;
        width  = static_cast<uint32_t>(texture.width);
        height = static_cast<uint32_t>(texture.height);
        const NSUInteger bytes_per_row = texture.width * 4;
        id<MTLBuffer>    staging       = [pImpl->device newBufferWithLength:bytes_per_row * texture.height
                                                            options:MTLResourceStorageModeShared];
        if (staging == nil) return false;

        id<MTLCommandBuffer>      command = [pImpl->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit    = [command blitCommandEncoder];
        [blit copyFromTexture:texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                     toBuffer:staging
            destinationOffset:0
       destinationBytesPerRow:bytes_per_row
     destinationBytesPerImage:bytes_per_row * texture.height];
        [blit endEncoding];
        [command commit];
        // Deliberately synchronous, and deliberately not on the frame path:
        // a readback has no later point at which to observe completion.
        [command waitUntilCompleted];

        rgba.assign(static_cast<const uint8_t*>(staging.contents),
                    static_cast<const uint8_t*>(staging.contents) + bytes_per_row * texture.height);
        return true;
    }
}
#endif

} // namespace wallpaper::metal
