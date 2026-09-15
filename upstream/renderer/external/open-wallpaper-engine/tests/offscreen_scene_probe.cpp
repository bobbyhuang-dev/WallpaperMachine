// Explicit diagnostic tool. Renders only imported scene assets to private GPU
// images: no surface, swapchain, AppKit window, audio device or desktop capture.
#include "Audio/SoundManager.h"
#include "Audio/AudioResponseService.h"
#include "Particle/ParticleSystem.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "WPSceneParser.hpp"
#include "WPPkgFs.hpp"
#include "SceneSourceResolver.hpp"
#include <charconv>
#include "SpecTexs.hpp"
#include "Vulkan/Device.hpp"
#include "Vulkan/TextureCache.hpp"
#include "Vulkan/Util.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/PrePass.hpp"
#include "VulkanRender/PassCommon.hpp"
#include "VulkanRender/Resource.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Interface/IImageParser.h"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace wallpaper;
using namespace wallpaper::vulkan;
namespace {
void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
uint16_t PackageVersion(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    uint32_t length = 0;
    file.read(reinterpret_cast<char*>(&length), sizeof(length));
    if (!file || length < 5 || length > 64) return SceneParseRequest::kUnknownPkgVersion;
    std::string stamp(length, '\0');
    file.read(stamp.data(), length);
    if (!file || !stamp.starts_with("PKGV")) return SceneParseRequest::kUnknownPkgVersion;
    uint16_t version = 0;
    const auto [end, ec] = std::from_chars(stamp.data() + 4, stamp.data() + stamp.size(), version);
    return ec == std::errc{} && end == stamp.data() + stamp.size()
        ? version : SceneParseRequest::kUnknownPkgVersion;
}
void Ppm(const std::filesystem::path& path, const uint8_t* rgba, int w, int h) {
    std::ofstream file(path, std::ios::binary);
    file << "P6\n" << w << ' ' << h << "\n255\n";
    for (int i = 0; i < w * h; ++i) file.write(reinterpret_cast<const char*>(rgba + i * 4), 3);
}
void Submit(Device& device, vvk::CommandBuffer& command) {
    Check(command.End() == VK_SUCCESS, "end command");
    VkSubmitInfo submit { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1, .pCommandBuffers = command.address() };
    Check(device.graphics_queue().handle.Submit(submit, {}) == VK_SUCCESS, "submit");
    Check(device.handle().WaitIdle() == VK_SUCCESS, "wait idle");
}
void Begin(vvk::CommandBuffer& command) {
    Check(command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT }) == VK_SUCCESS, "begin command");
}
// Exercise production's batching plan, including reused attachments and clears.
void ExecuteBatched(Device& device, RenderingResources& rr, const std::vector<VulkanPass*>& passes) {
    for (std::size_t i = 0; i < passes.size();) {
        auto* custom = dynamic_cast<CustomShaderPass*>(passes[i]);
        if (!custom) { passes[i++]->execute(device, rr); continue; }
        std::vector<CustomShaderPass*> run;
        std::vector<CustomPassBatchCandidate> candidates;
        while (i < passes.size()) {
            custom = dynamic_cast<CustomShaderPass*>(passes[i]);
            if (!custom) break;
            ++i;
            run.push_back(custom);
            candidates.push_back(custom->preRecord(device, rr));
        }
        for (const auto& entry : PlanCustomPassBatches(candidates).entries) {
            if (entry.kind == CustomPassBatchKind::ClearImage) {
                run[entry.first]->recordClear(device, rr); continue;
            }
            std::array<VkClearValue, 2> values {entry.render.clear_value, {}};
            VkRenderPassBeginInfo begin {
                .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .renderPass = entry.render.render_pass,
                .framebuffer = entry.render.framebuffer,
                .renderArea = {{0,0}, {entry.render.extent.width, entry.render.extent.height}},
                .clearValueCount = CustomPassBeginRenderPassClearValueCount(entry.render),
                .pClearValues = values.data(),
            };
            rr.command.BeginRenderPass(begin, VK_SUBPASS_CONTENTS_INLINE);
            for (auto j = entry.first; j < entry.last; ++j)
                if (candidates[j].visible) run[j]->recordDraw(device, rr);
            rr.command.EndRenderPass();
        }
    }
}

void ReadImage(Device& device, vvk::CommandBuffer& command, const ImageParameters& image,
               const std::filesystem::path& path) {
    VmaBufferParameters buffer;
    Check(CreateReadbackBuffer(device.vma_allocator(), image.extent.width * image.extent.height * 4, buffer), "readback allocation");
    Begin(command);
    VkImageMemoryBarrier barrier {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image.handle,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    command.PipelineBarrier(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, barrier);
    VkBufferImageCopy region { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = image.extent };
    command.CopyImageToBuffer(image.handle, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, *buffer.handle, spanone { region });
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, barrier);
    Submit(device, command);
    void* bytes = nullptr;
    Check(buffer.handle.MapMemory(&bytes) == VK_SUCCESS, "map readback");
    Check(vmaInvalidateAllocation(device.vma_allocator(), buffer.handle.Allocation(), 0, VK_WHOLE_SIZE) == VK_SUCCESS, "invalidate readback");
    Ppm(path, static_cast<const uint8_t*>(bytes), image.extent.width, image.extent.height);
    buffer.handle.UnMapMemory();
}
}
int main() {
    try {
        const char* project = std::getenv("WE_TEST_PROJECT");
        const char* assets = std::getenv("WE_TEST_ASSETS");
        const char* output = std::getenv("WE_TEST_OUTPUT");
        Check(project && assets && output, "Set WE_TEST_PROJECT, WE_TEST_ASSETS, WE_TEST_OUTPUT");
        const std::filesystem::path out(output);
        std::filesystem::create_directories(out);
        const char* audio_hz_env = std::getenv("WE_TEST_AUDIO_HZ");
        double      audio_hz     = 0.0;
        if (audio_hz_env) {
            char* end = nullptr;
            audio_hz  = std::strtod(audio_hz_env, &end);
            Check(end != audio_hz_env && *end == '\0' && std::isfinite(audio_hz) &&
                      audio_hz >= 0.0 && audio_hz <= 6000.0,
                  "WE_TEST_AUDIO_HZ must be 0..6000");
            audio::ResetAudioResponseServiceForTesting();
        }
        SceneSourcePaths paths;
        std::string error;
        Check(ResolveSceneSourcePaths(project, &paths, &error), error.c_str());
        fs::VFS vfs;
        Check(vfs.Mount("/assets", fs::CreatePhysicalFs(assets), "assets"), "assets mount");
        if (std::filesystem::exists(paths.pkg_path)) {
            Check(vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs(paths.pkg_path)), "package mount");
        } else {
            Check(vfs.Mount("/assets", fs::CreatePhysicalFs(paths.pkg_dir)), "scene directory mount");
        }
        Check(vfs.Mount("/cache", fs::CreatePhysicalFs((out / "cache").string(), true), "cache"), "cache mount");
        InstallVirtualAssets(vfs);
        ProjectProperties properties;
        Check(ParseProjectProperties(project, &properties, &error), error.c_str());
        auto source = vfs.Open("/assets/" + paths.pkg_entry);
        Check(source != nullptr, "scene source");
        WPSceneParser parser;
        audio::SoundManager sound; // Never Init/Play.
        auto scene = parser.Parse(SceneParseRequest {
            .scene_id = paths.scene_id, .project_path = project,
            .project_properties = &properties, .pkg_version = PackageVersion(paths.pkg_path),
        }, source->ReadAllStr(), vfs, sound);
        Check(scene != nullptr, "parse scene");
        if (audio_hz_env) {
            const char* enabled = std::getenv("WE_TEST_AUDIO_ENABLED");
            scene->runtime->SetAudioResponseEnabled(! enabled || std::string_view(enabled) != "0");
        }
        for (int i = 0; i < 20; ++i) {
            scene->runtime->Tick(1.0 / 60.0);
            scene->runtime->PumpTextLayerCache();
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        std::vector<std::string> text_names;
        const auto collect_text = [&](auto&& self, SceneNode* node) -> void {
            if (!node) return;
            if (scene->runtime->NodeTextState(node->Name())) text_names.push_back(node->Name());
            for (const auto& child : node->GetChildren()) self(self, child.get());
        };
        collect_text(collect_text, scene->sceneGraph.get());
        std::size_t text_index = 0;
        for (const auto& name : text_names) {
            const auto state = scene->runtime->NodeTextState(name);
            std::cout << name << " font=" << state->resolved_font_path << " kind=" << state->resolved_font_kind
                      << " text=" << state->text << " size=" << state->raster_size.transpose() << std::endl;
            const auto image = scene->imageParser->Parse(TextTextureName(name));
            if (image && !image->slots.empty()) {
                const auto& mip = image->slots[0].mipmaps[0];
                std::vector<uint8_t> pixels(mip.data.get(), mip.data.get() + mip.size);
                for (std::size_t i = 0; i < pixels.size(); i += 4)
                    for (int c = 0; c < 3; ++c) pixels[i+c] = pixels[i+c] * pixels[i+3] / 255;
                // Layer names are untrusted package data, not output paths.
                Ppm(out / ("text-" + std::to_string(text_index++) + ".ppm"), pixels.data(), mip.width, mip.height);
            }
        }
        auto graph = sceneToRenderGraph(*scene);
        Instance instance;
        std::vector<Extension> instance_extensions { { true, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME } };
        Check(Instance::Create(instance, instance_extensions, {}), "create instance");
        std::vector<Extension> extensions { { true, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME } };
        Check(instance.ChoosePhysicalDevice([&](auto gpu) { return Device::CheckGPU(gpu, extensions, {}); }), "choose GPU");
        Device device;
        const auto extent = ResolveScreenBoundRenderTargetSizes(*scene, {1920, 1080});
        Check(extent.width <= 8192 && extent.height <= 8192, "probe source extent exceeds 8192");
        for (auto& [name, rt] : scene->renderTargets) {
            if (rt.bind.enable && !rt.bind.screen) {
                const auto* parent = scene->FindRenderTarget(rt.bind.name);
                Check(parent != nullptr, "missing render target binding");
                rt.width = ResolveScreenBoundRenderTargetDimension(parent->width, rt.bind.scale);
                rt.height = ResolveScreenBoundRenderTargetDimension(parent->height, rt.bind.scale);
            }
            if (rt.has_mipmap) rt.mipmap_level = std::max(3u, static_cast<uint32_t>(std::floor(std::log2(std::min(rt.width, rt.height))))) - 2u;
        }
        scene->shaderValueUpdater->SetScreenSize(extent.width, extent.height);
        Check(Device::Create(instance, extensions, extent, device), "create device");
        StagingBuffer vertices(device, 8 * 1024 * 1024, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        StagingBuffer dynamic(device, 8 * 1024 * 1024, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        Check(vertices.allocate() && dynamic.allocate(), "allocate buffers");
        vvk::CommandBuffers commands;
        Check(device.cmd_pool().Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, commands) == VK_SUCCESS, "allocate commands");
        RenderingResources rr {};
        rr.command = vvk::CommandBuffer(commands[0], device.handle().Dispatch());
        rr.vertex_buf = &vertices; rr.dyn_buf = &dynamic;
        auto nodes = graph->topologicalOrder();
        auto releases = graph->getLastReadTexs(nodes);
        std::vector<VulkanPass*> passes;
        PrePass pre(PrePass::Desc {});
        pre.prepare(*scene, device, rr);
        passes.push_back(&pre);
        std::ofstream trace(out / "passes.txt");
        for (std::size_t i = 0; i < nodes.size(); ++i) {
            auto* pass = static_cast<VulkanPass*>(graph->getPass(nodes[i]));
            if (!std::getenv("WE_TEST_NO_REUSE")) {
                for (auto* tex : releases[i]) pass->addReleaseTexs(spanone<const std::string_view> {tex->key()});
            }
            pass->prepare(*scene, device, rr);
            Check(pass->prepared(), "pass failed to prepare");
            passes.push_back(pass);
            if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
                const auto& d = custom->desc();
                trace << i << " id=" << d.node->ID() << " " << d.node->Name() << " material="
                      << d.node->Mesh()->Material()->name << " visible="
                      << (!d.visibility_node || d.visibility_node->EffectiveVisible()) << " output="
                      << d.output << " image=" << d.vk_output.handle << " clear=" << d.clear_on_first_use << '\n';
                for (std::size_t t = 0; t < d.textures.size(); ++t) {
                    trace << "  " << t << ": " << d.textures[t];
                    if (!d.vk_textures[t].slots.empty()) trace << " image=" << d.vk_textures[t].getActive().handle;
                    if (d.sprites_map.contains(t)) {
                        const auto& f = d.sprites_map.at(t).GetCurFrame();
                        trace << " sprite=" << f.x << ',' << f.y << " axis=" << f.xAxis[0] << ',' << f.xAxis[1] << ',' << f.yAxis[0] << ',' << f.yAxis[1];
                    }
                    trace << '\n';
                }
            }
        }
        auto result = device.tex_cache().Query(std::string(SpecTex_Default), ToTexKey(*scene->FindRenderTarget(SpecTex_Default)), true);
        Check(result.has_value(), "result target");
        for (int frame = 0; frame < 3; ++frame) {
            if (audio_hz_env) {
                // Synthetic PCM only. Submit after GPU setup so the live-input
                // timeout cannot expire while shaders/pipelines are compiling.
                std::array<float, 2400> pcm {};
                for (size_t i = 0; i < pcm.size(); ++i) {
                    pcm[i] = 0.025f * std::sin(2.0 * 3.141592653589793 * audio_hz * i / 12000.0);
                }
                const auto generation = audio::CurrentAudioSpectrumSnapshot().generation;
                Check(audio::SubmitMonoAudioFrames(12000, pcm.size(), pcm.data(), &error),
                      error.c_str());
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
                while (audio::CurrentAudioSpectrumSnapshot().generation <= generation &&
                       std::chrono::steady_clock::now() < deadline) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                Check(audio::CurrentAudioSpectrumSnapshot().generation > generation,
                      "synthetic PCM was not analyzed");
                scene->paritileSys->Emitt();
            }
            scene->runtime->Tick(1.0 / 60.0);
            // Same update/upload ordering as the production renderer initially.
            Begin(rr.command);
            vertices.recordUpload(rr.command);
            dynamic.recordUpload(rr.command);
            if (!std::getenv("WE_TEST_DUMP_PASSES")) ExecuteBatched(device, rr, passes);
            else for (auto* pass : passes) {
                pass->execute(device, rr);
                if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
                    Submit(device, rr.command);
                    ReadImage(device, rr.command, custom->desc().vk_output, out / ("pass-" + std::to_string(custom->desc().node->ID()) + ".ppm"));
                    Begin(rr.command);
                }
            }
            Submit(device, rr.command);
            ReadImage(device, rr.command, *result, out / ("frame-" + std::to_string(frame) + ".ppm"));
            if (audio_hz_env) scene->PassFrameTime(1.0 / 60.0);
        }
        for (auto* pass : passes) pass->destory(device, rr);
        device.handle().WaitIdle();
        std::cout << "Offscreen scene output: " << out << '\n';
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
