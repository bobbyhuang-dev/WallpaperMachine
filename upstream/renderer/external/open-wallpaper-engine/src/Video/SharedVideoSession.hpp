#pragma once

#include "VideoTextureSource.hpp"

#include <cstdint>
#include <memory>
#include <string>

namespace wallpaper
{
struct Image;

namespace video
{

/// Lets several display surfaces consume one running decoder.
///
/// What is shared is the decode: one `VideoTextureSource`, one thread, one
/// frame queue, one decoded frame in flight. What is not shared is everything
/// a surface owns — the GPU import, visibility, pause reasons, target frame
/// rate and presentation resources all stay per surface, because each surface
/// renders on its own Vulkan device and a hidden surface must stop its own
/// exclusive work without stopping anyone else's playback.
///
/// Sharing is only offered to consumers that are actually equivalent: same
/// media, and a playback rate the running session is already using. A consumer
/// that asks for something the session cannot serve is detached onto its own
/// private decoder rather than forced into someone else's timeline.
///
/// Off by default; `SetSharedVideoDecodeEnabled` opts in. With it off,
/// `AcquireVideoTextureSource` returns a private source per call, which is the
/// behaviour that existed before.
void SetSharedVideoDecodeEnabled(bool enabled);
bool SharedVideoDecodeEnabled();

/// Distinct decoder instances the registry currently holds.
std::uint32_t SharedVideoDecodeSessionCount();
/// Surfaces currently consuming those decoders. Equal to the session count
/// when nothing is actually being shared.
std::uint32_t SharedVideoDecodeConsumerCount();

/// Returns a source for `image`, shared with an equivalent live consumer when
/// sharing is enabled and one exists, otherwise newly created.
///
/// The returned handle is always owned by exactly one consumer: releasing it
/// releases that consumer's claim, and the underlying decoder is destroyed once
/// the last claim goes away.
std::shared_ptr<VideoTextureSource> AcquireVideoTextureSource(const Image& image,
                                                              std::string* error);

/// Drops every session with no remaining consumers. Called when a renderer
/// tears down so a decoder cannot outlive the last surface that wanted it.
void ReleaseIdleVideoSessions();

} // namespace video
} // namespace wallpaper
