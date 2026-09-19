#pragma once

/// Guards against compiling one FFmpeg major's struct layouts into calls that
/// reach another major's libraries.
///
/// Homebrew publishes several FFmpeg formulae and links only the default one
/// into the shared `/opt/homebrew/include`, so a machine can offer two sets of
/// libav* headers whose `AVFrame` and `AVCodecContext` differ by several
/// removed fields. The link line names one; the include search order can
/// deliver the other. Nothing about that combination fails to compile: the
/// early members still line up, and the mismatch surfaces only as fields read
/// at the wrong offset -- a frame whose `pts` is right and whose
/// `best_effort_timestamp` is a neighbouring field's bytes, for instance, which
/// looks like a plain video that will not advance rather than like a build
/// problem.
///
/// The build keeps the two in step (see `wescene_prefer_ffmpeg_headers`); this
/// is the check that says so out loud instead of decoding through a layout the
/// libraries do not share. Every translation unit that includes this header
/// compares its own compiled-in majors, so the answer describes that unit's
/// headers and not some other target's -- which is why the definition below
/// has internal linkage. A plain `inline` would let the linker keep one
/// definition and discard the rest, and under the very failure this guards
/// against those definitions do not hold the same constants, so one unit could
/// end up answering for another unit's headers.

#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/version.h>
#include <libavformat/avformat.h>
#include <libavformat/version.h>
#include <libavutil/avutil.h>
#include <libavutil/version.h>
}

namespace wallpaper::video
{

/// Empty when the loaded libav* majors are the ones this translation unit was
/// compiled against, and a message naming the offending library otherwise.
static inline std::string FfmpegAbiMismatch()
{
    const struct {
        const char*  library;
        unsigned     compiled;
        unsigned     loaded;
    } libraries[] = {
        { "libavutil", LIBAVUTIL_VERSION_MAJOR, avutil_version() >> 16 },
        { "libavcodec", LIBAVCODEC_VERSION_MAJOR, avcodec_version() >> 16 },
        { "libavformat", LIBAVFORMAT_VERSION_MAJOR, avformat_version() >> 16 },
    };

    for (const auto& library : libraries) {
        if (library.compiled == library.loaded) continue;
        return std::string("this build compiled against ") + library.library + " " +
               std::to_string(library.compiled) + " but loaded " +
               std::to_string(library.loaded) +
               "; the two describe different structure layouts, so decoding would read "
               "frame and codec fields at the wrong offsets. Check that the FFmpeg "
               "headers pkg-config resolved come first in the include search order.";
    }
    return {};
}

} // namespace wallpaper::video
