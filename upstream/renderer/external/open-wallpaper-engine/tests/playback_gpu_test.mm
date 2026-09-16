// Surface-free regression coverage. All images and input frames are synthetic.
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

#include <gtest/gtest.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <functional>
#include <memory>
#include <stdexcept>
#include <unordered_map>
#include <unistd.h>
#include <sys/wait.h>
#include <utility>

#include "Image.hpp"
#include "Interface/IShaderValueUpdater.h"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "Vulkan/Device.hpp"
#include <vulkan/vulkan_metal.h>
#include "Vulkan/Util.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/PassCommon.hpp"
#include "VulkanRender/Resource.hpp"

namespace wallpaper::vulkan {
struct TextureCacheVideoInteropTestAccess {
    static ImageSlotsRef Create(TextureCache& cache, Image& image,
                                std::shared_ptr<video::VideoTextureSource> source) {
        return cache.CreateVideoTex(image, std::move(source));
    }
    static size_t CachedImports(const TextureCache& cache, const std::string& key) {
        const auto it = cache.m_video_tex_map.find(key);
        return it == cache.m_video_tex_map.end() ? 0 : it->second->imported_frames.size();
    }
};
}

namespace {
using namespace wallpaper;
using namespace wallpaper::vulkan;
using Bytes = std::vector<uint8_t>;
using Color = std::array<uint8_t, 4>;

void Require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
void VkRequire(VkResult result, const char* operation) {
    Require(result == VK_SUCCESS, std::string(operation) + ": " + vvk::ToString(result));
}

// Each wrapper replaces only the fixture device's dispatch table. The registry is
// thread-local because every API call in these tests stays on the render thread.
// No loader entry point, shared GPU, or production failpoint is changed.
struct DispatchScope {
    static thread_local DispatchScope* current;
    vvk::DeviceDispatch& dispatch;
    vvk::DeviceDispatch saved;
    VkDevice device;
    bool fail_import = false;
    bool fail_submit = false;
    bool timeout_wait = false;
    bool fail_reset = false;
    VkResult idle_result = VK_SUCCESS;
    uint64_t waits = 0;
    uint64_t submits = 0;
    uint64_t pushes = 0;
    VkBuffer watched_destination = VK_NULL_HANDLE;
    std::vector<VkBufferCopy> copies;

    explicit DispatchScope(Device& dev)
        : dispatch(const_cast<vvk::DeviceDispatch&>(dev.handle().Dispatch())),
          saved(dispatch), device(*dev.handle()) {
        Require(current == nullptr, "nested dispatch scope");
        current = this;
        dispatch.vkCreateImage = CreateImage;
        dispatch.vkQueueSubmit = Submit;
        dispatch.vkWaitForFences = Wait;
        dispatch.vkResetFences = Reset;
        dispatch.vkDeviceWaitIdle = Idle;
        dispatch.vkCmdCopyBuffer = Copy;
        dispatch.vkCmdPushDescriptorSetKHR = Push;
    }
    ~DispatchScope() { dispatch = saved; current = nullptr; }
    static VKAPI_ATTR VkResult VKAPI_CALL CreateImage(VkDevice d, const VkImageCreateInfo* info,
                                                       const VkAllocationCallbacks* alloc, VkImage* out) {
        auto& s = *current;
        for (auto* p = static_cast<const VkBaseInStructure*>(info->pNext); p; p = p->pNext) {
            if (d == s.device && s.fail_import && p->sType == VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT) {
                s.fail_import = false;
                return VK_ERROR_OUT_OF_DEVICE_MEMORY;
            }
        }
        return s.saved.vkCreateImage(d, info, alloc, out);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Submit(VkQueue q, uint32_t n, const VkSubmitInfo* infos, VkFence f) {
        auto& s = *current;
        ++s.submits;
        if (std::exchange(s.fail_submit, false)) return VK_ERROR_OUT_OF_HOST_MEMORY;
        return s.saved.vkQueueSubmit(q, n, infos, f);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Wait(VkDevice d, uint32_t n, const VkFence* fs,
                                               VkBool32 all, uint64_t timeout) {
        auto& s = *current;
        ++s.waits;
        if (d == s.device && std::exchange(s.timeout_wait, false)) return VK_TIMEOUT;
        return s.saved.vkWaitForFences(d, n, fs, all, timeout);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Reset(VkDevice d, uint32_t n, const VkFence* fs) {
        auto& s = *current;
        if (d == s.device && std::exchange(s.fail_reset, false)) return VK_ERROR_OUT_OF_HOST_MEMORY;
        return s.saved.vkResetFences(d, n, fs);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Idle(VkDevice d) {
        auto& s = *current;
        return d == s.device && s.idle_result != VK_SUCCESS ? s.idle_result : s.saved.vkDeviceWaitIdle(d);
    }
    static VKAPI_ATTR void VKAPI_CALL Copy(VkCommandBuffer c, VkBuffer src, VkBuffer dst,
                                           uint32_t n, const VkBufferCopy* ranges) {
        auto& s = *current;
        if (dst == s.watched_destination) s.copies.insert(s.copies.end(), ranges, ranges + n);
        s.saved.vkCmdCopyBuffer(c, src, dst, n, ranges);
    }
    static VKAPI_ATTR void VKAPI_CALL Push(VkCommandBuffer c, VkPipelineBindPoint p, VkPipelineLayout l,
                                           uint32_t set, uint32_t n, const VkWriteDescriptorSet* writes) {
        auto& s = *current;
        ++s.pushes;
        s.saved.vkCmdPushDescriptorSetKHR(c, p, l, set, n, writes);
    }
};
thread_local DispatchScope* DispatchScope::current = nullptr;

class SyntheticVideo final : public video::VideoTextureSource {
public:
    CVPixelBufferRef buffer = nullptr;
    video::VideoTextureFrame frame {};
    bool fail_refresh = false;
    video::VideoPlaybackState playback {};
    SyntheticVideo(uint32_t w = 32, uint32_t h = 32) { Resize(w, h); }
    ~SyntheticVideo() override { if (buffer) CVPixelBufferRelease(buffer); }
    void Resize(uint32_t w, uint32_t h, OSType format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        CVPixelBufferRef replacement = nullptr;
        NSDictionary* attributes = @{ (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                      (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES };
        Require(CVPixelBufferCreate(kCFAllocatorDefault, w, h, format,
                                    (__bridge CFDictionaryRef)attributes, &replacement) == kCVReturnSuccess,
                "IOSurface-backed Metal-compatible CVPixelBuffer prerequisite");
        if (buffer) CVPixelBufferRelease(buffer);
        buffer = replacement;
        frame.width = w; frame.height = h;
        frame.pixel_buffer = buffer;
        frame.io_surface = CVPixelBufferGetIOSurface(buffer);
        frame.pixel_format = format;
        frame.plane_count = static_cast<uint32_t>(CVPixelBufferGetPlaneCount(buffer));
        Set(0);
    }
    void Set(uint64_t generation, uint8_t y = 128, uint8_t u = 128, uint8_t v = 128,
             CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
        frame.generation = generation;
        frame.pts_seconds = static_cast<double>(generation) / 60.0;
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
        Require(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess, "lock synthetic frame");
        if (CVPixelBufferGetPlaneCount(buffer) == 2) {
            auto* luma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
            auto* chroma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
            for (size_t row = 0; row < frame.height; ++row)
                memset(luma + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), y, frame.width);
            for (size_t row = 0; row < frame.height / 2; ++row)
                for (size_t x = 0; x < frame.width; x += 2) {
                    auto* p = chroma + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x;
                    p[0] = u; p[1] = v;
                }
        } else {
            auto* raw = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
            for (size_t row = 0; row < frame.height; ++row)
                for (size_t x = 0; x < frame.width; ++x) {
                    auto* p = raw + row * CVPixelBufferGetBytesPerRow(buffer) + x * 4;
                    p[0] = v; p[1] = u; p[2] = y; p[3] = 255;
                }
        }
        Require(CVPixelBufferUnlockBaseAddress(buffer, 0) == kCVReturnSuccess, "unlock synthetic frame");
    }
    bool prime(std::string*) override { return true; }
    bool syncPlayback(const video::VideoPlaybackState& state, std::string*) override { playback = state; return true; }
    bool refreshFrame(std::string* error) override {
        if (!std::exchange(fail_refresh, false)) return true;
        if (error) *error = "synthetic one-shot decoder refresh error";
        return false;
    }
    video::VideoTextureFrame currentFrame() const override { return frame; }
    double durationSeconds() const override { return 1000.0; }
    double playbackSeconds() const override { return frame.pts_seconds; }
    uint64_t loopCount() const override { return 0; }
};

struct TestUpdater final : IShaderValueUpdater {
    std::array<float, 4> color { 1, 0, 0, 1 };
    unsigned calls = 0;
    std::function<void(SceneNode*)> geometry;
    void FrameBegin() override {}
    void FrameEnd() override {}
    void InitUniforms(SceneNode*, const ExistsUniformOp&) override {}
    void UpdateUniforms(SceneNode* node, sprite_map_t&, const UpdateUniformOp& update) override {
        ++calls;
        update("g_TestColor", ShaderValue(color));
        if (geometry) geometry(node);
    }
    void MouseInput(double, double) override {}
    void SetTexelSize(float, float) override {}
    void SetScreenSize(i32, i32) override {}
};

// Rust emits split texture/sampler descriptors. Convert that real compiler
// output to its equivalent combined-descriptor variant to exercise the legacy
// write path on the GPU, without another compiler or a fake pass.
void CombineSampler(ShaderCode& code, uint32_t image_binding, uint32_t sampler_binding) {
    struct Instruction {
        std::vector<uint32_t> words;
        uint32_t op() const { return words[0] & 0xffff; }
    };
    std::vector<Instruction> instructions;
    for (size_t offset = 5; offset < code.size();) {
        const size_t count = code[offset] >> 16;
        Require(count != 0 && offset + count <= code.size(), "valid Rust SPIR-V instruction");
        instructions.push_back({std::vector<uint32_t>(code.begin() + offset, code.begin() + offset + count)});
        offset += count;
    }
    uint32_t image = 0, sampler = 0, pointer = 0, image_type = 0, sampled_type = 0;
    for (const auto& ins : instructions) {
        const auto& w = ins.words;
        if (ins.op() == 71 && w.size() == 4 && w[2] == 33) {
            if (w[3] == image_binding) image = w[1];
            if (w[3] == sampler_binding) sampler = w[1];
        }
    }
    if (!image && !sampler) return;
    Require(image && sampler, "complete split descriptor pair");
    for (const auto& ins : instructions)
        if (ins.op() == 59 && ins.words[2] == image) pointer = ins.words[1];
    for (const auto& ins : instructions)
        if (ins.op() == 32 && ins.words[1] == pointer) image_type = ins.words[3];
    for (const auto& ins : instructions)
        if (ins.op() == 27 && ins.words[2] == image_type) sampled_type = ins.words[1];
    Require(pointer && image_type && sampled_type, "split image types");
    std::unordered_map<uint32_t, bool> loaded_images, loaded_samplers;
    for (const auto& ins : instructions) {
        if (ins.op() != 61) continue;
        if (ins.words[3] == image) loaded_images.emplace(ins.words[2], true);
        if (ins.words[3] == sampler) loaded_samplers.emplace(ins.words[2], true);
    }
    ShaderCode output(code.begin(), code.begin() + 5);
    unsigned rewritten_samples = 0;
    for (auto ins : instructions) {
        auto& w = ins.words;
        const auto op = ins.op();
        if ((op == 5 || op == 71) && (w[1] == sampler || loaded_samplers.contains(w[1]))) continue;
        if (op == 59 && w[2] == sampler) continue;
        if (op == 61 && w[3] == sampler) continue;
        if (op == 27 && w[1] == sampled_type) continue;
        if (op == 32 && w[1] == pointer) w[3] = sampled_type;
        if (op == 61 && w[3] == image) w[1] = sampled_type;
        if (op == 86 && loaded_images.contains(w[3]) && loaded_samplers.contains(w[4])) {
            w = {(4u << 16) | 83u, sampled_type, w[2], w[3]}; // OpCopyObject
            ++rewritten_samples;
        }
        if (op == 15) {
            size_t interface_start = 3;
            while (interface_start < w.size()) {
                const auto word = w[interface_start++];
                if ((word & 0xff) == 0 || (word & 0xff00) == 0 ||
                    (word & 0xff0000) == 0 || (word & 0xff000000) == 0) break;
            }
            w.erase(std::remove(w.begin() + interface_start, w.end(), sampler), w.end());
            w[0] = (static_cast<uint32_t>(w.size()) << 16) | op;
        }
        output.insert(output.end(), w.begin(), w.end());
        if (op == 25 && w[1] == image_type) {
            const std::array<uint32_t,3> sampled {(3u << 16) | 27u, sampled_type, image_type};
            output.insert(output.end(), sampled.begin(), sampled.end());
        }
    }
    Require(rewritten_samples != 0, "combined shader must really sample its descriptor");
    code = std::move(output);
}

class PlaybackGPU : public ::testing::Test {
protected:
    Instance instance;
    Device device;
    std::unique_ptr<StagingBuffer> vertices;
    std::unique_ptr<StagingBuffer> dynamic;
    vvk::CommandBuffers commands;
    RenderingResources rr {};
    Scene scene;
    TestUpdater* updater = nullptr;
    std::vector<std::unique_ptr<CustomShaderPass>> owned_passes;
    std::vector<std::shared_ptr<SceneNode>> nodes;
    std::vector<std::shared_ptr<SceneShader>> shaders;
    CustomPassExecutionScratch scratch;
    bool recording = false;
    bool submitted = false;
    bool initialized = false;
    uint64_t serial = 0;

    void SetUp() override {
        try {
            std::vector<Extension> ix {{true, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME}};
            Require(Instance::Create(instance, ix, {}), "Vulkan instance/MoltenVK prerequisite");
            std::vector<Extension> dx {{true, VK_EXT_METAL_OBJECTS_EXTENSION_NAME},
                                       {true, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME}};
            Require(instance.ChoosePhysicalDevice([&](auto gpu) { return Device::CheckGPU(gpu, dx, {}); }),
                    "Metal import and push-descriptor capable surface-free GPU prerequisite");
            Require(Device::Create(instance, dx, {32, 32}, device), "surface-free Vulkan device prerequisite");
            initialized = true;
            vertices = std::make_unique<StagingBuffer>(device, 256, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
            dynamic = std::make_unique<StagingBuffer>(device, 256, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
            Require(vertices->allocate() && dynamic->allocate(), "fixture staging allocation");
            VkRequire(device.cmd_pool().Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, commands), "allocate command");
            rr.command = vvk::CommandBuffer(commands[0], device.handle().Dispatch());
            rr.vertex_buf = vertices.get(); rr.dyn_buf = dynamic.get();
            NewFence();
            auto value_updater = std::make_unique<TestUpdater>();
            updater = value_updater.get();
            scene.shaderValueUpdater = std::move(value_updater);
            scene.activeCamera = nullptr;
        } catch (const std::exception& e) { FAIL() << e.what(); }
    }
    void TearDown() override {
        if (!initialized) return;
        const auto idle = device.handle().WaitIdle();
        if (idle != VK_SUCCESS) std::terminate();
        if (submitted) device.tex_cache().CompleteVideoFrame();
        else if (recording) {
            if (rr.command.Reset() != VK_SUCCESS) std::terminate();
            device.tex_cache().AbandonVideoFrameRecording();
        }
        if (vertices) vertices->finishUpload(submitted);
        if (dynamic) dynamic->finishUpload(submitted);
        submitted = recording = false;
        scratch.passes.clear(); scratch.candidates.clear(); scratch.plan.entries.clear();
        for (auto& pass : owned_passes) pass->destory(device, rr);
        owned_passes.clear();
        rr.command = {};
        commands = {};
        rr.fence_frame.reset();
        if (vertices) vertices->destroy();
        if (dynamic) dynamic->destroy();
        Require(device.tex_cache().Clear(), "fixture cache completion");
    }
    void NewFence() {
        rr.fence_frame.reset();
        VkRequire(device.handle().CreateFence(VkFenceCreateInfo {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}, rr.fence_frame), "create fence");
    }
    ImageSlotsRef Register(const std::string& key, const std::shared_ptr<SyntheticVideo>& source,
                           TextureCache* cache = nullptr) {
        Image image;
        image.key = key; image.header.isVideo = true;
        image.header.width = source->frame.width; image.header.height = source->frame.height;
        auto result = TextureCacheVideoInteropTestAccess::Create(cache ? *cache : device.tex_cache(), image, source);
        Require(!result.slots.empty() && result.video_frame_owner, "register real video source: " + key);
        return result;
    }
    bool Update(const std::string& key, ImageSlotsRef& ref, double pts = 0) {
        std::string error;
        return device.tex_cache().UpdateVideoFrame(key, video::VideoPlaybackState {.scene_elapsed_seconds = pts}, &ref, &error);
    }
    Bytes Read(const ImageParameters& image) {
        Bytes bytes;
        std::string error;
        Require(device.tex_cache().ReadbackImageSample(image, 0, 0, image.extent.width, image.extent.height, &bytes, &error), error);
        return bytes;
    }
    Bytes Reference(const SyntheticVideo& source, bool rgba = true) {
        std::string error;
        void* retained = video::CreateAppleVideoMetalTextureForDevice(source.frame, nullptr, nullptr, &error);
        Require(retained != nullptr, error);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)retained;
        Bytes bytes(source.frame.width * source.frame.height * 4);
        [texture getBytes:bytes.data() bytesPerRow:source.frame.width * 4
                 fromRegion:MTLRegionMake2D(0, 0, source.frame.width, source.frame.height) mipmapLevel:0];
        video::ReleaseAppleVideoMetalTexture(retained);
        if (rgba) for (size_t i = 0; i < bytes.size(); i += 4) std::swap(bytes[i], bytes[i + 2]);
        return bytes;
    }
    static void ExpectSolid(const Bytes& bytes, Color color) {
        ASSERT_FALSE(bytes.empty());
        ASSERT_EQ(bytes.size() % 4, 0u);
        for (size_t i = 0; i < bytes.size(); ++i) {
            if (bytes[i] != color[i % 4]) {
                ADD_FAILURE() << "pixel " << i / 4 << " channel " << i % 4 << ": "
                              << unsigned(bytes[i]) << " expected " << unsigned(color[i % 4]);
                return;
            }
        }
    }
    void Begin() {
        Require(!recording && !submitted, "only one fixture draw in flight");
        std::string error;
        Require(device.tex_cache().BeginVideoFrameRecording(&error), error);
        recording = true;
        VkRequire(rr.command.Reset(), "reset command");
        VkRequire(rr.command.Begin(VkCommandBufferBeginInfo {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                                           .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT}), "begin command");
    }
    void Upload() {
        Require(vertices->recordUpload(rr.command) && dynamic->recordUpload(rr.command), "record upload");
    }
    VkResult SubmitOnly() {
        VkRequire(rr.command.End(), "end command");
        VkSubmitInfo info {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = rr.command.address()};
        const auto result = device.graphics_queue().handle.Submit(info, *rr.fence_frame);
        if (result == VK_SUCCESS) {
            device.tex_cache().MarkVideoFrameSubmitted();
            submitted = true; recording = false;
        }
        return result;
    }
    void Complete() {
        VkRequire(rr.fence_frame.Wait(), "wait draw fence");
        device.tex_cache().CompleteVideoFrame();
        vertices->finishUpload(true); dynamic->finishUpload(true);
        submitted = false;
        const auto reset = rr.fence_frame.Reset();
        if (reset != VK_SUCCESS) NewFence();
    }
    void Submit() { VkRequire(SubmitOnly(), "submit draw"); Complete(); }
    void Abandon() {
        Require(!submitted, "cannot abandon submitted work");
        VkRequire(rr.command.Reset(), "discard recording");
        vertices->finishUpload(false); dynamic->finishUpload(false);
        device.tex_cache().AbandonVideoFrameRecording(); recording = false;
    }
    std::shared_ptr<SceneShader> Compile(bool texture, bool uniform, bool combined = false) {
        shader::RustShaderRequest request;
        request.shader_name = "playback_gpu/" + std::to_string(serial++);
        request.scene_id = "synthetic"; request.cache_enabled = false;
        request.stages = {{ShaderType::VERTEX,
            "attribute vec2 a_Position;\nvarying vec2 v_Uv;\nvoid main() { v_Uv = a_Position * 0.5 + vec2(0.5); gl_Position=vec4(a_Position,0.0,1.0); }\n"},
            {ShaderType::FRAGMENT, std::string("varying vec2 v_Uv;\n") +
                (texture ? "uniform sampler2D g_Texture0;\n" : "") +
                (uniform ? "uniform vec4 g_TestColor;\n" : "") +
                "void main() { gl_FragColor=" + (texture ? "texture2D(g_Texture0,v_Uv)" : "vec4(0.0,1.0,0.0,1.0)") +
                (uniform ? (texture ? " * g_TestColor" : " * 0.0 + g_TestColor") : "") + "; }\n"}};
        if (texture) request.textures.push_back(shader::RustShaderTextureInfo {.slot = 0, .present = true, .enabled = true});
        shader::RustShaderOutput output;
        Require(shader::CompileRustShaderProgram(request, output), "Rust shader prerequisite: " + shader::LastRustShaderError());
        auto result = std::make_shared<SceneShader>();
        result->name = request.shader_name;
        result->codes = std::move(output.codes);
        result->rust_reflection_json = std::move(output.reflection_json);
        if (combined) {
            const auto image_binding = output.reflection.binding_map.at("g_Texture0").binding;
            const auto sampler_binding = output.reflection.binding_map.at("_we_Sampler_g_Texture0").binding;
            for (auto& code : result->codes) CombineSampler(code, image_binding, sampler_binding);
            // The Rust compiler intentionally omits OpName debug strings. Keep
            // its authored names/UBO layout and update metadata with the same
            // descriptor transformation applied to the executable SPIR-V.
            auto reflection = nlohmann::json::parse(*result->rust_reflection_json);
            auto& bindings = reflection.at("descriptor_bindings");
            bindings.erase(std::remove_if(bindings.begin(), bindings.end(), [&](const auto& binding) {
                return binding.at("binding") == sampler_binding;
            }), bindings.end());
            for (auto& binding : bindings) {
                if (binding.at("binding") == image_binding)
                    binding["descriptor"] = "combined_image_sampler";
            }
            result->rust_reflection_json = reflection.dump();
        }
        shaders.push_back(result);
        return result;
    }
    std::string Target(uint32_t w = 32, uint32_t h = 32) {
        const std::string name = "_rt_gpu_" + std::to_string(serial++);
        scene.renderTargets[name] = SceneRenderTarget {.width = static_cast<i32>(w), .height = static_cast<i32>(h)};
        return name;
    }
    CustomShaderPass& Pass(bool texture = true, bool uniform = false,
                           std::string output = {}, bool dyn = false,
                           VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT,
                           std::shared_ptr<SceneShader> shader = {}) {
        if (output.empty()) output = Target();
        auto mesh = std::make_shared<SceneMesh>(dyn);
        SceneVertexArray array({{"a_Position", VertexType::FLOAT2, false}}, dyn ? 4 : 3);
        if (dyn) {
            const std::array<float, 8> points {-1,-1, 1,-1, -1,1, 1,1};
            Require(array.SetVertex("a_Position", points), "set dynamic quad vertices");
        } else {
            const std::array<float, 6> points {-1,-1, 3,-1, -1,3};
            Require(array.SetVertex("a_Position", points), "set fullscreen triangle vertices");
        }
        mesh->AddVertexArray(std::move(array));
        SceneMaterial material;
        material.customShader.shader = shader ? std::move(shader) : Compile(texture, uniform);
        mesh->AddMaterial(std::move(material));
        auto node = std::make_shared<SceneNode>(); node->AddMesh(mesh); nodes.push_back(node);
        CustomShaderPass::Desc desc;
        desc.node = node.get(); desc.visibility_node = node.get(); desc.output = output;
        desc.sample_count = samples;
        if (texture) desc.textures = {""};
        auto pass = std::make_unique<CustomShaderPass>(desc);
        pass->desc().clear_on_first_use = true;
        pass->prepare(scene, device, rr);
        Require(pass->prepared(), "prepare real CustomShaderPass");
        owned_passes.push_back(std::move(pass));
        return *owned_passes.back();
    }
    void Bind(CustomShaderPass& pass, const ImageSlotsRef& ref) { pass.desc().vk_textures.at(0) = ref; }
    void Frame(std::span<VulkanPass* const> passes, bool batched = true) {
        // CPU writes precede command recording and the staging transaction.
        Require(device.tex_cache().BeginVideoFrameRecording(), "begin CPU frame scope");
        recording = true;
        Require(UpdatePreparedPasses(device, rr, passes), "update prepared passes");
        VkRequire(rr.command.Reset(), "reset frame command");
        VkRequire(rr.command.Begin(VkCommandBufferBeginInfo {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                                           .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT}), "begin frame command");
        Upload();
        if (batched) ExecutePreparedPasses(device, rr, passes, scratch);
        else for (auto* pass : passes) if (pass && pass->prepared()) pass->execute(device, rr);
        Submit();
    }
    void Draw(CustomShaderPass& pass, bool batched = true) {
        VulkanPass* ptr = &pass; Frame(std::span<VulkanPass* const>(&ptr, 1), batched);
    }
    Bytes BufferRead(StagingBuffer& staging, VkDeviceSize size) {
        VmaBufferParameters readback;
        Require(CreateReadbackBuffer(device.vma_allocator(), size, readback), "allocate buffer readback");
        Begin();
        VkBufferMemoryBarrier before {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = staging.gpuBuf(), .offset = 0, .size = size};
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, before);
        VkBufferCopy copy {.size = size};
        rr.command.CopyBuffer(staging.gpuBuf(), *readback.handle, spanone {copy});
        VkBufferMemoryBarrier after {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = *readback.handle, .offset = 0, .size = size};
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, after);
        Submit();
        void* mapped = nullptr;
        VkRequire(readback.handle.MapMemory(&mapped), "map buffer readback");
        VkRequire(vmaInvalidateAllocation(device.vma_allocator(), readback.handle.Allocation(), 0, VK_WHOLE_SIZE), "invalidate readback");
        Bytes bytes(static_cast<uint8_t*>(mapped), static_cast<uint8_t*>(mapped) + size);
        readback.handle.UnMapMemory();
        return bytes;
    }
    void UploadBuffer(StagingBuffer& staging) {
        Begin(); Require(staging.recordUpload(rr.command), "record test staging upload");
        VkRequire(SubmitOnly(), "submit test staging");
        VkRequire(rr.fence_frame.Wait(), "wait test staging");
        staging.finishUpload(true); Complete();
    }
};

TEST_F(PlaybackGPU, SameGenerationSkipsConversion) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 40, 90, 170);
    auto ref = Register("same", source);
    auto& pass = Pass(); Bind(pass, ref); Draw(pass);
    const auto expected = Reference(*source);
    EXPECT_EQ(Read(pass.desc().vk_output), expected);
    const auto stats = device.tex_cache().VideoSubmissionStats();
    for (int i = 0; i < 3; ++i) { ASSERT_TRUE(Update("same", ref)); Bind(pass, ref); Draw(pass); }
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().conversion_calls, stats.conversion_calls);
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().new_imports, stats.new_imports);
    auto old = ref;
    source->Set(2, 180, 170, 80);
    ASSERT_TRUE(Update("same", ref)); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source));
    Bind(pass, old); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), expected);
}

TEST_F(PlaybackGPU, SteadyGenerationsReuseRetiredDestinations) {
    auto& pass = Pass();
    const std::array<CFStringRef, 3> matrices {kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_2020};
    for (OSType range : {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange}) {
        for (auto matrix : matrices) {
            auto source = std::make_shared<SyntheticVideo>(); source->Resize(32, 32, range);
            const auto key = "steady-" + std::to_string(serial++);
            auto ref = Register(key, source);
            uint64_t created = 0;
            uint64_t reused = 0;
            for (uint64_t i = 1; i <= 40; ++i) {
                source->Set(i, static_cast<uint8_t>(30 + (i * 19) % 180),
                            static_cast<uint8_t>(70 + (i * 13) % 110), static_cast<uint8_t>(60 + (i * 7) % 130), matrix);
                ASSERT_TRUE(Update(key, ref, i / 60.0));
                EXPECT_DOUBLE_EQ(source->playback.scene_elapsed_seconds, i / 60.0);
                EXPECT_DOUBLE_EQ(source->currentFrame().pts_seconds, i / 60.0);
                Bind(pass, ref); Draw(pass);
                EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source)) << "generation " << i;
                auto stats = device.tex_cache().VideoSubmissionStats();
                if (i == 12) { created = stats.converted_destinations_created; reused = stats.converted_destinations_reused; }
                if (i > 12) {
                    EXPECT_EQ(stats.converted_destinations_created, created);
                    EXPECT_EQ(stats.converted_destinations_reused, reused + i - 12);
                }
                EXPECT_LE(TextureCacheVideoInteropTestAccess::CachedImports(device.tex_cache(), key), 4u);
                EXPECT_LE(stats.pool_cached_texture_count, 4u);
                EXPECT_LE(stats.pool_cached_bytes, 64u * 1024u * 1024u);
            }
        }
    }
}

TEST_F(PlaybackGPU, RecordedConsumersSurviveCacheEviction) {
    auto source = std::make_shared<SyntheticVideo>();
    auto ref = Register("six", source);
    std::array<CustomShaderPass*, 6> passes;
    auto shader = Compile(true, false);
    for (auto& p : passes) p = &Pass(true, false, {}, false, VK_SAMPLE_COUNT_1_BIT, shader);
    std::array<Bytes, 6> expected;
    Begin();
    for (auto* pass : passes) {
        Bind(*pass, ref);
        ASSERT_TRUE(pass->updateFrame(device, rr));
    }
    Upload();
    for (size_t i = 0; i < passes.size(); ++i) {
        source->Set(i + 1, 35 + i * 30, 80 + i * 15, 175 - i * 17);
        expected[i] = Reference(*source);
        ASSERT_TRUE(Update("six", ref));
        Bind(*passes[i], ref);
        passes[i]->execute(device, rr);
        passes[i]->desc().vk_textures[0] = {};
        ref = {};
    }
    Submit();
    for (size_t i = 0; i < passes.size(); ++i) EXPECT_EQ(Read(passes[i]->desc().vk_output), expected[i]);
}

TEST_F(PlaybackGPU, RetainedConsumerSurvivesOtherPassAndUpdateFailure) {
    auto a = std::make_shared<SyntheticVideo>(); a->Set(1, 50, 90, 170);
    auto b = std::make_shared<SyntheticVideo>(); b->Set(1, 170, 140, 60);
    auto ar = Register("a", a); auto br = Register("b", b);
    const auto old_pixels = Reference(*a);
    auto& retained = Pass(); auto& moving = Pass(); auto& other = Pass();
    Bind(retained, ar); Bind(moving, ar); Bind(other, br);
    Draw(retained);
    retained.desc().visibility_node->SetVisible(false);
    for (uint64_t i = 2; i < 12; ++i) {
        a->Set(i, 20 + i * 13, 110, 160); b->Set(i, 200 - i * 11, 160, 90);
        ASSERT_TRUE(Update("a", ar)); ASSERT_TRUE(Update("b", br));
        Bind(moving, ar); Bind(other, br);
        std::array<VulkanPass*, 3> passes {&moving, &retained, &other}; Frame(passes);
        EXPECT_EQ(Read(moving.desc().vk_output), Reference(*a));
        EXPECT_EQ(Read(other.desc().vk_output), Reference(*b));
    }
    retained.desc().textures[0] = "a";
    retained.desc().video_textures[0] = true;
    a->fail_refresh = true;
    retained.desc().visibility_node->SetVisible(true); Draw(retained);
    EXPECT_EQ(Read(retained.desc().vk_output), old_pixels);
    EXPECT_FALSE(a->fail_refresh);
}

TEST_F(PlaybackGPU, ConversionAndImportFailurePreserveCurrentFrame) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 70, 160, 100);
    auto ref = Register("failure", source); auto& pass = Pass();
    const auto old = Reference(*source); auto owner = ref.video_frame_owner;
    source->Resize(32, 32, kCVPixelFormatType_32BGRA);
    source->Set(2, 230, 10, 40);
    source->frame.pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    source->frame.plane_count = 2;
    ASSERT_FALSE(Update("failure", ref)); EXPECT_EQ(ref.video_frame_owner, owner);
    Bind(pass, ref); Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), old);
    source->Resize(32, 32); source->Set(3, 180, 80, 180);
    {
        DispatchScope scope(device); scope.fail_import = true;
        ASSERT_FALSE(Update("failure", ref)); EXPECT_FALSE(scope.fail_import);
    }
    EXPECT_EQ(ref.video_frame_owner, owner); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), old);
    ASSERT_TRUE(Update("failure", ref)); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source));
}

TEST_F(PlaybackGPU, ResizeAndDirectBgraKeepSeparateLifetimes) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 80, 80, 170);
    auto ref = Register("resize", source); auto retained = ref;
    const auto old = Reference(*source); auto& pass = Pass();
    for (const auto extent : {std::array<uint32_t,2>{64,32}, {32,32}}) {
        source->Resize(extent[0], extent[1]); source->Set(++serial, 120, 160, 80);
        ASSERT_TRUE(Update("resize", ref));
        EXPECT_EQ(ref.getActive().extent.width, extent[0]); EXPECT_EQ(ref.getActive().extent.height, extent[1]);
        EXPECT_EQ(Read(ref.getActive()), Reference(*source, false));
    }
    const auto before = device.tex_cache().VideoSubmissionStats().conversion_calls;
    source->Resize(32, 32, kCVPixelFormatType_32BGRA); source->Set(++serial, 20, 180, 40);
    ASSERT_TRUE(Update("resize", ref)); Bind(pass, ref); Draw(pass);
    ExpectSolid(Read(pass.desc().vk_output), {20,180,40,255});
    const auto bgra_owner = ref.video_frame_owner;
    source->Set(++serial, 90, 30, 210); ASSERT_TRUE(Update("resize", ref));
    EXPECT_EQ(ref.video_frame_owner, bgra_owner);
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().conversion_calls, before);
    Bind(pass, ref); Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {90,30,210,255});
    source->Resize(32, 32); source->Set(++serial, 180, 100, 130);
    ASSERT_TRUE(Update("resize", ref)); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source));
    Bind(pass, retained); Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), old);
    const auto stats = device.tex_cache().VideoSubmissionStats();
    EXPECT_LE(stats.pool_cached_texture_count, 4u); EXPECT_LE(stats.pool_cached_bytes, 64u * 1024u * 1024u);
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice(); ASSERT_NE(metal, nil);
    video::AppleVideoMetalTexturePool pool((__bridge void*)metal);
    auto* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4096 height:4097 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared; descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> large = [metal newTextureWithDescriptor:descriptor]; ASSERT_NE(large, nil);
    ASSERT_GT(large.allocatedSize, 64u * 1024u * 1024u);
    pool.Recycle((__bridge_retained void*)large);
    EXPECT_EQ(pool.CachedTextureCount(), 0u); EXPECT_EQ(pool.CachedBytes(), 0u);
}

TEST_F(PlaybackGPU, RecordingDiscardAndSubmissionRecoveryKeepOwners) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 80, 170, 100);
    auto ref = Register("recovery", source); auto& pass = Pass(); Bind(pass, ref);
    auto expected = Reference(*source);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); pass.execute(device, rr); Abandon();
    Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); pass.execute(device, rr);
    std::weak_ptr<const void> weak = ref.video_frame_owner;
    pass.desc().vk_textures[0] = {};
    ref = {};
    for (uint64_t generation = 2; generation <= 8; ++generation) {
        source->Set(generation, 40 + generation * 20, 100, 170);
        ASSERT_TRUE(Update("recovery", ref));
    }
    ASSERT_TRUE(device.tex_cache().WaitForPendingUploads());
    ASSERT_EQ(SubmitOnly(), VK_SUCCESS);
    {
        DispatchScope scope(device); scope.timeout_wait = true;
        EXPECT_EQ(rr.fence_frame.Wait(), VK_TIMEOUT);
        EXPECT_FALSE(device.tex_cache().BeginVideoFrameRecording());
        EXPECT_FALSE(device.tex_cache().Clear()); EXPECT_FALSE(weak.expired());
    }
    Complete(); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    EXPECT_TRUE(weak.expired());
    Bind(pass, ref);
    expected = Reference(*source);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); pass.execute(device, rr);
    {
        DispatchScope scope(device); scope.fail_submit = true;
        EXPECT_EQ(SubmitOnly(), VK_ERROR_OUT_OF_HOST_MEMORY);
        EXPECT_EQ(scope.waits, 0u);
        Abandon(); EXPECT_EQ(scope.waits, 0u);
    }
    Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); pass.execute(device, rr);
    ASSERT_EQ(SubmitOnly(), VK_SUCCESS);
    {
        DispatchScope scope(device); scope.fail_reset = true;
        Complete(); EXPECT_FALSE(scope.fail_reset);
    }
    Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    // Import submissions own independent commands/fences. An unsuccessful
    // transition must not wait on its unsignalled fence, and a completed fence
    // whose Reset failed must be recreated before a later transition.
    ASSERT_TRUE(device.tex_cache().WaitForPendingUploads());
    source->Set(20, 170, 90, 180);
    {
        DispatchScope scope(device); scope.fail_submit = true;
        EXPECT_FALSE(Update("recovery", ref));
        EXPECT_FALSE(scope.fail_submit);
        EXPECT_EQ(scope.waits, 0u);
    }
    Bind(pass, ref); Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    ASSERT_TRUE(Update("recovery", ref));
    {
        DispatchScope scope(device); scope.fail_reset = true;
        EXPECT_FALSE(device.tex_cache().WaitForPendingUploads());
        EXPECT_FALSE(scope.fail_reset);
    }
    const auto allocations = device.tex_cache().VideoSubmissionStats().fence_allocations;
    source->Set(21, 120, 180, 80);
    ASSERT_TRUE(Update("recovery", ref));
    EXPECT_GT(device.tex_cache().VideoSubmissionStats().fence_allocations, allocations);
    Bind(pass, ref); Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source));
}

TEST_F(PlaybackGPU, ClearInvalidatesOldPoolWithoutInvalidatingOwners) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 90, 80, 180);
    auto old = Register("clear", source);
    const auto pixels = Reference(*source, false);
    Begin(); device.tex_cache().PinVideoFrame(old);
    EXPECT_FALSE(device.tex_cache().Clear()); Abandon();
    Begin(); device.tex_cache().PinVideoFrame(old); ASSERT_EQ(SubmitOnly(), VK_SUCCESS);
    EXPECT_FALSE(device.tex_cache().Clear()); Complete();
    ASSERT_TRUE(device.tex_cache().Clear());
    EXPECT_EQ(Read(old.getActive()), pixels);
    source->Set(2, 150, 160, 80); auto fresh = Register("fresh", source);
    const auto count = device.tex_cache().VideoSubmissionStats().pool_cached_texture_count;
    old = {};
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().pool_cached_texture_count, count);
    fresh = {};
    ASSERT_TRUE(device.tex_cache().Clear());
    ::testing::FLAGS_gtest_death_test_style = "threadsafe";
    EXPECT_EXIT({
        alarm(5);
        auto terminal = std::make_unique<TextureCache>(device);
        auto input = std::make_shared<SyntheticVideo>();
        auto held = Register("terminal-loss", input, terminal.get());
        Require(terminal->WaitForPendingUploads(), "complete actual import before simulated loss");
        VkRequire(device.handle().WaitIdle(), "real idle before simulated loss");
        {
            DispatchScope scope(device); scope.idle_result = VK_ERROR_DEVICE_LOST;
            Require(device.handle().WaitIdle() == VK_ERROR_DEVICE_LOST, "controlled loss");
            terminal->DiscardAfterDeviceLoss();
            Require(!terminal->BeginVideoFrameRecording(), "lost cache must stay terminal");
            held = {}; terminal.reset();
        }
        _exit(0);
    }, ::testing::ExitedWithCode(0), "");
    EXPECT_EXIT({
        alarm(5);
        std::set_terminate([] { _exit(73); });
        auto terminal = std::make_unique<TextureCache>(device);
        auto input = std::make_shared<SyntheticVideo>();
        auto held = Register("terminal-unknown", input, terminal.get());
        // The real queue is idle, but the import remains logically pending.
        VkRequire(device.handle().WaitIdle(), "real idle before simulated wait error");
        held = {};
        DispatchScope scope(device); scope.timeout_wait = true; scope.idle_result = VK_ERROR_UNKNOWN;
        terminal.reset();
        _exit(74);
    }, ::testing::ExitedWithCode(73), "");
}

TEST_F(PlaybackGPU, PartialUploadsPreserveUntouchedBytes) {
    StagingBuffer staging(device, 256, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    ASSERT_TRUE(staging.allocate()); StagingBufferRef ref; ASSERT_TRUE(staging.allocateSubRef(256, ref));
    UploadBuffer(staging); Bytes expected(256, 0); EXPECT_EQ(BufferRead(staging, 256), expected);
    const auto write = [&](size_t offset, Bytes bytes) {
        Require(staging.writeToBuf(ref, bytes, offset), "partial staging write");
        std::copy(bytes.begin(), bytes.end(), expected.begin() + offset);
    };
    write(5, {0x11,0x22,0x33}); write(69, {0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7});
    write(8, {0x44,0x55}); write(6, {0x66,0x77});
    ASSERT_TRUE(staging.writeToBuf(ref, {}, 0)); ASSERT_TRUE(staging.writeToBuf(ref, {}, 256));
    {
        DispatchScope scope(device); scope.watched_destination = staging.gpuBuf();
        UploadBuffer(staging);
        ASSERT_EQ(scope.copies.size(), 2u);
        EXPECT_EQ(scope.copies[0].srcOffset, 4u); EXPECT_EQ(scope.copies[0].dstOffset, 4u); EXPECT_EQ(scope.copies[0].size, 8u);
        EXPECT_EQ(scope.copies[1].srcOffset, 68u); EXPECT_EQ(scope.copies[1].dstOffset, 68u); EXPECT_EQ(scope.copies[1].size, 8u);
    }
    EXPECT_EQ(BufferRead(staging, 256), expected);
    write(5, {0x11,0x66,0x77});
    {
        DispatchScope scope(device); scope.watched_destination = staging.gpuBuf(); UploadBuffer(staging);
        EXPECT_TRUE(scope.copies.empty());
    }
    EXPECT_EQ(BufferRead(staging, 256), expected);
}

TEST_F(PlaybackGPU, DiscardedUploadRetriesAndPendingStorageCannotMutate) {
    StagingBuffer staging(device, 256, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    ASSERT_TRUE(staging.allocate()); StagingBufferRef ref; ASSERT_TRUE(staging.allocateSubRef(256, ref));
    UploadBuffer(staging);
    Bytes value {11,22,33,44}; ASSERT_TRUE(staging.writeToBuf(ref, value, 5));
    Begin(); ASSERT_TRUE(staging.recordUpload(rr.command));
    VkRequire(rr.command.End(), "end discarded upload");
    VkRequire(rr.command.Reset(), "reset discarded upload"); staging.finishUpload(false); Abandon();
    Begin(); ASSERT_TRUE(staging.recordUpload(rr.command));
    Bytes replacement {99,88,77,66};
    EXPECT_FALSE(staging.writeToBuf(ref, replacement, 5));
    EXPECT_FALSE(staging.fillBuf(ref, 0, 256, 0xff));
    StagingBufferRef additional;
    EXPECT_FALSE(staging.allocateSubRef(512, additional));
    EXPECT_FALSE(staging.allocate()); EXPECT_FALSE(staging.recordUpload(rr.command));
    staging.unallocateSubRef(ref);
    VkRequire(SubmitOnly(), "submit retry"); VkRequire(rr.fence_frame.Wait(), "wait retry");
    staging.finishUpload(true); Complete();
    Bytes expected(256, 0); std::copy(value.begin(), value.end(), expected.begin() + 5);
    EXPECT_EQ(BufferRead(staging, 256), expected);
    ASSERT_TRUE(staging.writeToBuf(ref, replacement, 5));
    ASSERT_TRUE(staging.allocateSubRef(512, additional)); UploadBuffer(staging);
    std::copy(replacement.begin(), replacement.end(), expected.begin() + 5);
    EXPECT_EQ(BufferRead(staging, 256), expected);
}

TEST_F(PlaybackGPU, GrowthReuploadsPreservedAndInitializedData) {
    StagingBuffer staging(device, 256, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    for (bool before_first_upload : {false, true}) {
        ASSERT_TRUE(staging.allocate()); StagingBufferRef first, second;
        ASSERT_TRUE(staging.allocateSubRef(256, first)); Bytes pattern(256);
        for (size_t i = 0; i < pattern.size(); ++i) pattern[i] = static_cast<uint8_t>(i * 37 + 11);
        ASSERT_TRUE(staging.writeToBuf(first, pattern));
        if (!before_first_upload) UploadBuffer(staging);
        ASSERT_TRUE(staging.allocateSubRef(512, second));
        Bytes front {7,8,9,10}, back {21,22,23,24};
        ASSERT_TRUE(staging.writeToBuf(second, front)); ASSERT_TRUE(staging.writeToBuf(second, back, 508));
        UploadBuffer(staging);
        Bytes expected(second.offset + second.size, 0);
        std::copy(pattern.begin(), pattern.end(), expected.begin() + first.offset);
        std::copy(front.begin(), front.end(), expected.begin() + second.offset);
        std::copy(back.begin(), back.end(), expected.begin() + second.offset + 508);
        EXPECT_EQ(BufferRead(staging, expected.size()), expected);
        staging.destroy();
    }
    StagingBuffer odd(device, 260, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    ASSERT_TRUE(odd.allocate()); StagingBufferRef first, aligned;
    ASSERT_TRUE(odd.allocateSubRef(260, first));
    const auto alignment = std::max<VkDeviceSize>(16, device.limits().minUniformBufferOffsetAlignment);
    ASSERT_TRUE(odd.allocateSubRef(64, aligned, alignment)); EXPECT_EQ(aligned.offset % alignment, 0u);
    ASSERT_TRUE(odd.fillBuf(aligned, 0, 64, 0x79)); UploadBuffer(odd);
    auto actual = BufferRead(odd, aligned.offset + aligned.size);
    Bytes expected(actual.size(), 0); std::fill(expected.begin() + aligned.offset, expected.end(), 0x79);
    EXPECT_EQ(actual, expected);
    auto& pass = Pass(false, true, {}, true); updater->color = {0,1,0,1}; Draw(pass);
    StagingBufferRef huge; ASSERT_TRUE(dynamic->allocateSubRef(8192, huge));
    updater->color = {0,0,1,1}; Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {0,0,255,255});
}

TEST_F(PlaybackGPU, FrameUpdatesAreVisibleBeforeUpload) {
    for (bool batched : {true, false}) {
        updater->color = {1,0,0,1}; updater->geometry = {};
        auto& pass = Pass(false, true, {}, true);
        const auto set_half = [](SceneNode* node, bool right) {
            const float left = right ? 0.0f : -1.0f, right_x = right ? 1.0f : 0.0f;
            const std::array<float,8> positions {left,-1,right_x,-1,left,1,right_x,1};
            Require(node->Mesh()->GetVertexArray(0).SetVertexs(0, positions), "update dynamic geometry");
            node->Mesh()->SetDirty();
        };
        set_half(pass.desc().node, false);
        Draw(pass, batched);
        // A truly unchanged frame between initialization and this frame matters:
        // an upload-before-update implementation cannot hide behind initial dirt.
        Draw(pass, batched);
        updater->calls = 0;
        updater->color = {0,1,0,1}; updater->geometry = [&](SceneNode* n) { set_half(n, true); };
        Draw(pass, batched); EXPECT_EQ(updater->calls, 1u);
        auto bytes = Read(pass.desc().vk_output);
        for (uint32_t y = 0; y < 32; ++y) for (uint32_t x = 0; x < 32; ++x) {
            const auto i = (y * 32 + x) * 4;
            EXPECT_EQ(bytes[i], 0u); EXPECT_EQ(bytes[i+1], x >= 16 ? 255u : 0u); EXPECT_EQ(bytes[i+2], 0u);
        }
        updater->color = {0,0,1,1}; updater->geometry = [&](SceneNode* n) { set_half(n, false); };
        Draw(pass, batched); EXPECT_EQ(updater->calls, 2u);
        bytes = Read(pass.desc().vk_output);
        for (uint32_t y = 0; y < 32; ++y) for (uint32_t x = 0; x < 32; ++x) {
            const auto i = (y * 32 + x) * 4;
            EXPECT_EQ(bytes[i], 0u); EXPECT_EQ(bytes[i+1], 0u); EXPECT_EQ(bytes[i+2], x < 16 ? 255u : 0u);
        }
        pass.desc().visibility_node->SetVisible(false); Draw(pass, batched);
        EXPECT_EQ(updater->calls, 2u); ExpectSolid(Read(pass.desc().vk_output), {0,0,0,0});
        updater->geometry = {};
    }
}

TEST_F(PlaybackGPU, GraphOrderingAndDescriptorWritesPreservePixels) {
    for (auto samples : {VK_SAMPLE_COUNT_1_BIT, VK_SAMPLE_COUNT_4_BIT}) {
        if (!(device.limits().framebufferColorSampleCounts & samples)) {
            RecordProperty("msaa4_variant", "not supported; single-sample cases still required"); continue;
        }
        const auto a_name = Target(), b_name = Target(), c_name = Target(), d_name = Target();
        auto& a = Pass(false, false, a_name, false, samples);
        auto& b = Pass(true, false, b_name, false, samples);
        ImageSlotsRef ar; ar.slots = {a.desc().vk_output}; Bind(b, ar);
        CopyPass copy(CopyPass::Desc {.src = b_name, .dst = c_name}); copy.prepare(scene, device, rr);
        ASSERT_TRUE(copy.prepared());
        auto& consumer = Pass(true, true, d_name, false, samples);
        updater->color = {1,1,1,1};
        ImageSlotsRef cr; cr.slots = {copy.desc().vk_dst}; Bind(consumer, cr);
        auto& adjacent = Pass(true, false, d_name, false, samples);
        adjacent.desc().preserve_target_contents = true; adjacent.desc().clear_on_first_use = false;
        Bind(adjacent, cr);
        auto& hidden = Pass(false, false, {}, false, samples); hidden.desc().visibility_node->SetVisible(false);
        std::array<VulkanPass*, 6> sequence {&a, &b, &copy, &consumer, &adjacent, &hidden};
        {
            DispatchScope scope(device); Frame(sequence);
            EXPECT_EQ(scope.pushes, 3u);
        }
        ExpectSolid(Read(a.desc().vk_output), {0,255,0,255});
        ExpectSolid(Read(b.desc().vk_output), {0,255,0,255});
        ExpectSolid(Read(copy.desc().vk_dst), {0,255,0,255});
        ExpectSolid(Read(consumer.desc().vk_output), {0,255,0,255});
        ExpectSolid(Read(hidden.desc().vk_output), {0,0,0,0});
        EXPECT_EQ(b.desc().vk_texture_bindings[0].image_descriptor_type, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
        EXPECT_GE(b.desc().vk_texture_bindings[0].sampler_binding, 0);
        for (bool uniform : {false, true}) {
            auto combined_shader = Compile(true, uniform, true);
            auto& combined = Pass(true, uniform, {}, false, samples, combined_shader);
            Bind(combined, cr);
            {
                DispatchScope scope(device); Draw(combined);
                EXPECT_EQ(scope.pushes, 1u);
            }
            EXPECT_EQ(combined.desc().vk_texture_bindings[0].image_descriptor_type,
                      VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
            EXPECT_EQ(combined.desc().vk_texture_bindings[0].sampler_binding, -1);
            ExpectSolid(Read(combined.desc().vk_output), {0,255,0,255});
        }
    }
}
} // namespace
