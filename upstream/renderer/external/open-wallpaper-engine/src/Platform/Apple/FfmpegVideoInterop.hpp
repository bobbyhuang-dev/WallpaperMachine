#pragma once

#include "Video/VideoTextureSource.hpp"

#include <cstdint>
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

void* CreateAppleVideoMetalTexture(const VideoTextureFrame& frame, std::string* error);
void* CreateAppleVideoMetalTextureForDevice(const VideoTextureFrame& frame,
                                            void* metal_device,
                                            std::string* error);
void ReleaseAppleVideoMetalTexture(void* handle);

} // namespace wallpaper::video
