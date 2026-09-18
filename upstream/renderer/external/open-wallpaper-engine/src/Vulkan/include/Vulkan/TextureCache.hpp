#pragma once

#include "Video/VideoFramePacing.hpp"
#include "Video/VideoTextureSource.hpp"
#include "Parameters.hpp"
#include "Type.hpp"
#include "Core/NoCopyMove.hpp"
#include "Core/MapSet.hpp"
#include "Core/RendererCounters.hpp"

#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <memory>
#include <vector>

namespace wallpaper
{

struct Image;
namespace video { class AppleVideoMetalTexturePool; }

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
    std::uint64_t conversion_calls { 0 };
    std::uint64_t converted_destinations_created { 0 };
    std::uint64_t converted_destinations_reused { 0 };
    std::uint64_t pool_cached_texture_count { 0 };
    std::uint64_t pool_cached_bytes { 0 };
    /// Largest the pooled set has been since this pool was created, which is
    /// what a reuse ceiling has to be judged against.
    std::uint64_t pool_peak_cached_bytes { 0 };
    std::uint64_t pool_hits { 0 };
    std::uint64_t pool_misses { 0 };
    std::uint64_t pool_recycles { 0 };
    std::uint64_t pool_evictions { 0 };
    std::uint64_t pool_refusals { 0 };
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

    enum class VideoFrameState { Idle, Recording, Submitted };
    bool Clear(std::string* error = nullptr);
    bool BeginVideoFrameRecording(std::string* error = nullptr);
    void PinVideoFrame(const ImageSlotsRef&);
    void MarkVideoFrameSubmitted();
    void CompleteVideoFrame();
    void AbandonVideoFrameRecording();
    void InvalidateVideoDestinationPool();
    bool WaitForPendingUploads(std::string* error = nullptr);
    void DiscardAfterDeviceLoss() noexcept;

    std::optional<ExImageParameters> CreateExTex(uint32_t witdh, uint32_t height, VkFormat,
                                                 VkImageTiling);
    ImageSlotsRef CreateTex(Image&);
    ImageSlotsRef ReplaceTex(Image&, std::string_view previous_key);
    void          CollectCompletedUploads();
    void          SetVideoPlaybackPaused(bool paused);
    void          SetVideoPlaybackRate(float rate);
    [[nodiscard]] VideoTextureSubmissionStats VideoSubmissionStats() const;
    /// Shortest frame period among the live video sources, in seconds, or 0
    /// when none of them can report one. The shortest is the safe answer: it
    /// is the rate at which something can still change.
    [[nodiscard]] double ShortestVideoFramePeriod() const;
    /// Counters owned by the scene, shared with the frame clock and the
    /// renderer. Sources created after this call receive it too.
    void                                      SetCounters(RendererCounters* counters);
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
    friend struct TextureCacheVideoInteropTestAccess;
    ImageSlotsRef CreateVideoTex(Image&, std::shared_ptr<video::VideoTextureSource>);
    struct ImportedVideoFrame;
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
        std::shared_ptr<ImportedVideoFrame> image_owner;
    };
    TextureUploadSubmissionSlot* acquireTextureUploadSubmissionSlot(std::string* error);
    bool                         waitForTextureUploadSlot(TextureUploadSubmissionSlot& slot,
                                                          std::string* error);
    bool                         ensureTextureUploadSlot(TextureUploadSubmissionSlot&, std::string* error);
    bool                         waitForPendingTextureUploads(std::string* error);
    void                         collectCompletedTextureUploads();
    void                         retireRuntimeTexture(std::string_view key);
    VideoImportSubmissionSlot* acquireVideoImportSubmissionSlot(std::string* error);
    bool                       waitForVideoImportSlot(VideoImportSubmissionSlot& slot,
                                                      std::string* error);
    bool                       waitForPendingVideoImports(std::string* error);
    bool                       ensureVideoImportFence(VideoImportSubmissionSlot&, std::string* error);
    vvk::CommandBuffers               m_tex_cmds;
    vvk::CommandBuffer                m_tex_cmd;
    std::vector<VideoImportSubmissionSlot> m_video_import_slots;
    uint64_t                              m_video_import_submit_serial { 0 };

    const Device&                m_device;
    Map<std::string, ImageSlots> m_tex_map;
    struct ImportedVideoFrame {
        /// Owns the imported frame: the Core Video texture wrapper, the pixel
        /// buffer and the Metal texture retire together when the last holder of
        /// this lease drops it.
        std::shared_ptr<void> frame_lease;
        ExImageParameters     image;
        uint64_t              generation { 0 };
        uint64_t              last_used { 0 };
        mutable uint64_t      last_pinned_recording { 0 };
        void*                 surface_identity { nullptr };
        uint32_t              pixel_format { 0 };
    };
    struct VideoTex {
        TextureSample                                    sample;
        std::shared_ptr<video::VideoTextureSource>       source;
        ImportedVideoFrame*                              current_frame { nullptr };
        std::vector<std::shared_ptr<ImportedVideoFrame>> imported_frames;
        uint64_t                                         frame_use_serial { 0 };
        /// Turns the displayed generation sequence into selected / reused /
        /// skipped, which is how a pacing change is falsified.
        video::VideoFrameSelectionTracker                selection;
        /// Decoder totals already reported, so the counters accumulate the
        /// delta rather than the running total of every source.
        uint64_t                                         reported_decode_outputs { 0 };
        uint64_t                                         reported_seeks { 0 };
    };
    static constexpr std::size_t kMaxImportedVideoFramesPerVideoTex { 4 };
    static constexpr std::size_t kMaxPendingVideoImportSubmissions { 2 };
    static constexpr std::size_t kMaxPendingTextureUploads { 8 };
    bool                CanReuseVideoFrameImport(const video::VideoTextureFrame& frame) const;
    std::shared_ptr<ImportedVideoFrame> FindImportedVideoFrame(
        VideoTex& video_tex, const video::VideoTextureFrame& frame, void* surface_identity) const;
    bool                EnsureVideoFrameCacheRoom(VideoTex& video_tex, std::string* error);
    /// Publishes how many decoder instances this cache consumes and, when
    /// there is exactly one, its identity, so source work can be attributed
    /// to a running decoder rather than to a file path.
    void                publishVideoSourceIdentity();
    Map<std::string, std::unique_ptr<VideoTex>> m_video_tex_map;
    video::VideoPlaybackState                   m_video_playback_state {};
    /// Null outside a scene, e.g. in tests and standalone tools.
    RendererCounters*                           m_counters { nullptr };
    VideoTextureSubmissionStats                 m_video_submission_stats {};
    std::shared_ptr<video::AppleVideoMetalTexturePool> m_video_destination_pool;
    VideoFrameState m_video_frame_state { VideoFrameState::Idle };
    uint64_t m_video_recording_serial { 0 };
    std::vector<std::shared_ptr<const void>> m_video_frame_pins;
    bool m_video_recycling_disabled { false };
    bool m_device_lost { false };
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
