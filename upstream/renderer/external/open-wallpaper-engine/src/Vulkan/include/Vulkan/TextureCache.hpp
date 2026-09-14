#pragma once

#include "Video/VideoTextureSource.hpp"
#include "Parameters.hpp"
#include "Type.hpp"
#include "Core/NoCopyMove.hpp"
#include "Core/MapSet.hpp"

#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <memory>
#include <vector>

namespace wallpaper
{

struct Image;

namespace vulkan
{

VkFormat             ToVkType(TextureFormat);
VkSamplerAddressMode ToVkType(TextureWrap);
VkFilter             ToVkType(TextureFilter);
VkSamplerCreateInfo  GenRenderTargetSamplerInfo();

enum class TexUsage
{
    COLOR,
    DEPTH,
    MSAA_COLOR,
};

using TexHash = std::size_t;

struct VideoTextureSubmissionStats {
    std::uint64_t update_calls { 0 };
    std::uint64_t cache_hits { 0 };
    std::uint64_t new_imports { 0 };
    std::uint64_t fence_waits { 0 };
    std::uint64_t evictions { 0 };
    std::uint64_t import_submission_slots { 0 };
    std::uint64_t command_buffer_allocations { 0 };
    std::uint64_t fence_allocations { 0 };
};

struct VideoImportSubmissionPlan {
    std::size_t pending_submissions { 0 };
    std::size_t available_slots { 0 };
    bool        must_destroy_resource { false };
};

enum class TextureUploadSynchronization
{
    Blocking,
    Deferred,
};

inline bool VideoImportSubmissionNeedsFenceWait(const VideoImportSubmissionPlan& plan) {
    if (plan.pending_submissions == 0) return false;
    if (plan.must_destroy_resource) return true;
    return plan.available_slots == 0 || plan.pending_submissions >= plan.available_slots;
}

inline video::VideoPlaybackState
ResolveEffectiveVideoPlaybackState(const video::VideoPlaybackState& global_state,
                                   const video::VideoPlaybackState& layer_state) {
    video::VideoPlaybackState effective_state = layer_state;
    effective_state.paused = global_state.paused || layer_state.paused;
    effective_state.rate =
        std::max(0.0f, global_state.rate) * std::max(0.0f, layer_state.rate);
    effective_state.scene_elapsed_seconds = layer_state.scene_elapsed_seconds;
    return effective_state;
}

struct TextureKey {
    i32           width;
    i32           height;
    TexUsage      usage;
    TextureFormat format;
    TextureSample sample;
    uint          mipmap_level { 1 };
    VkSampleCountFlagBits sample_count { VK_SAMPLE_COUNT_1_BIT };

    static TexHash HashValue(const TextureKey&);
};

// CPU-side planning only. Descriptor-visible color textures stay single-sampled;
// MSAA_COLOR is the private render-pass color sidecar resolved into COLOR.
VkSampleCountFlagBits PlannedTextureSampleCountForGpuAllocation(TextureKey key);

class TextureCache : NoCopy, NoMove {
public:
    TextureCache(const Device&);
    ~TextureCache();

    void Clear();

    std::optional<ExImageParameters> CreateExTex(uint32_t witdh, uint32_t height, VkFormat,
                                                 VkImageTiling);
    ImageSlotsRef CreateTex(Image&);
    ImageSlotsRef ReplaceTex(Image&, std::string_view previous_key);
    void          CollectCompletedUploads();
    void          SetVideoPlaybackPaused(bool paused);
    void          SetVideoPlaybackRate(float rate);
    [[nodiscard]] VideoTextureSubmissionStats VideoSubmissionStats() const;
    void                                      ResetVideoSubmissionStats();
    double                           GetVideoDuration(std::string_view key) const;
    bool UpdateVideoFrame(std::string_view key, const video::VideoPlaybackState& playback_state,
                          ImageSlotsRef* out, std::string* error = nullptr);
    bool ReadbackImageSample(const ImageParameters& image, uint32_t x, uint32_t y, uint32_t width,
                             uint32_t height, std::vector<std::uint8_t>* out,
                             std::string* error = nullptr);

    std::optional<ImageParameters> Query(std::string_view key, TextureKey content_hash,
                                         bool persist = false);

    void MarkShareReady(std::string_view key);

    void RecGenerateMipmaps(vvk::CommandBuffer& cmd, const ImageParameters& image) const;

private:
    ImageSlotsRef                     CreateTex(Image&, TextureUploadSynchronization);
    std::optional<VmaImageParameters> CreateTex(TextureKey);
    VkSampler                         GetOrCreateSampler(TextureKey, std::string* error);
    void*                             GetMetalDeviceHandle(std::string* error);
    void                              allocateCmd();
    struct TextureUploadSubmissionSlot {
        vvk::CommandBuffers              commands;
        vvk::CommandBuffer               command;
        vvk::Fence                       fence;
        bool                             pending { false };
        uint64_t                         submitted_serial { 0 };
        std::vector<VmaBufferParameters> staging_buffers;
    };
    struct VideoImportSubmissionSlot {
        vvk::CommandBuffers commands;
        vvk::CommandBuffer  command;
        vvk::Fence          fence;
        bool                pending { false };
        uint64_t            submitted_serial { 0 };
    };
    TextureUploadSubmissionSlot* acquireTextureUploadSubmissionSlot(std::string* error);
    bool                         waitForTextureUploadSlot(TextureUploadSubmissionSlot& slot,
                                                          std::string* error);
    bool                         waitForPendingTextureUploads(std::string* error);
    void                         collectCompletedTextureUploads();
    void                         retireRuntimeTexture(std::string_view key);
    VideoImportSubmissionSlot* acquireVideoImportSubmissionSlot(std::string* error);
    bool                       waitForVideoImportSlot(VideoImportSubmissionSlot& slot,
                                                      std::string* error);
    bool                       waitForPendingVideoImports(std::string* error);
    vvk::CommandBuffers               m_tex_cmds;
    vvk::CommandBuffer                m_tex_cmd;
    std::vector<VideoImportSubmissionSlot> m_video_import_slots;
    uint64_t                              m_video_import_submit_serial { 0 };

    const Device&                m_device;
    Map<std::string, ImageSlots> m_tex_map;
    struct ImportedVideoFrame {
        ExImageParameters     image;
        std::shared_ptr<void> metal_texture;
        uint64_t              generation { 0 };
        uint64_t              last_used { 0 };
        void*                 surface_identity { nullptr };
        uint32_t              pixel_format { 0 };
    };
    struct VideoTex {
        TextureSample                                    sample;
        std::shared_ptr<video::VideoTextureSource>       source;
        ImportedVideoFrame*                              current_frame { nullptr };
        std::vector<std::unique_ptr<ImportedVideoFrame>> imported_frames;
        uint64_t                                         frame_use_serial { 0 };
    };
    static constexpr std::size_t kMaxImportedVideoFramesPerVideoTex { 4 };
    static constexpr std::size_t kMaxPendingVideoImportSubmissions { 2 };
    static constexpr std::size_t kMaxPendingTextureUploads { 8 };
    bool                CanReuseVideoFrameImport(const video::VideoTextureFrame& frame) const;
    ImportedVideoFrame* FindImportedVideoFrame(VideoTex&                       video_tex,
                                               const video::VideoTextureFrame& frame,
                                               void* surface_identity) const;
    bool                EnsureVideoFrameCacheRoom(VideoTex& video_tex, std::string* error);
    Map<std::string, std::unique_ptr<VideoTex>> m_video_tex_map;
    video::VideoPlaybackState                   m_video_playback_state {};
    VideoTextureSubmissionStats                 m_video_submission_stats {};
    std::vector<TextureUploadSubmissionSlot>    m_texture_upload_slots;
    uint64_t                                    m_texture_upload_submit_serial { 0 };
    std::vector<ImageSlots>                     m_retired_runtime_textures;
    void*                                       m_metal_device { nullptr };
    bool                                        m_metal_device_queried { false };

    struct CachedSampler {
        TexHash      hash { 0 };
        vvk::Sampler sampler;
    };
    std::vector<CachedSampler> m_sampler_cache;

    struct QueryTex {
        idx                index { 0 };
        bool               share_ready { false };
        bool               persist { false };
        TexHash            content_hash;
        VmaImageParameters image;
        Set<std::string>   query_keys;
    };
    std::vector<std::unique_ptr<QueryTex>> m_query_texs;
    Map<std::string, QueryTex*>            m_query_map;
};

} // namespace vulkan
} // namespace wallpaper
