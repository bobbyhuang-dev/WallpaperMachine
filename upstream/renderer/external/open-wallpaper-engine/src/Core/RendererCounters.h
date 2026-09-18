#ifndef OWE_CORE_RENDERER_COUNTERS_H
#define OWE_CORE_RENDERER_COUNTERS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Renderer-side work counters.
 *
 * These exist to answer one question: when a surface is hidden or suspended,
 * does the renderer actually stop doing work for it? A decision recorded on the
 * application side proves only that a decision was delivered. Every counter
 * below is incremented on the production path that performs the work.
 *
 * Two groups, deliberately separated, because they answer different questions:
 *
 *   - Surface-exclusive work (OWE_RC_TIMER_WAKEUPS .. OWE_RC_SIMULATION_TICKS)
 *     must stop for a surface nobody can see.
 *   - Source work (OWE_RC_VIDEO_*) belongs to the decoded media, which may
 *     legitimately keep running while one of its consumers is hidden, as long
 *     as another consumer still presents it.
 *
 * Counting is off by default (see RendererCounters::SetEnabled). Reading is
 * pull-only: nothing is pushed, logged or written to disk per frame.
 */
typedef enum owe_renderer_counter {
    /* --- surface-exclusive --- */
    /* The frame clock fired. */
    OWE_RC_TIMER_WAKEUPS = 0,
    /* A draw was posted to the render looper by that tick. */
    OWE_RC_DRAW_REQUESTS,
    /* A tick that posted nothing because a draw was still in flight. */
    OWE_RC_DRAW_TICKS_SUPPRESSED,
    /* A posted draw reached the render path. */
    OWE_RC_DRAWS_EXECUTED,
    /* A posted draw was dropped because rendering was blocked or stopped. */
    OWE_RC_DRAWS_DROPPED,
    /* A command buffer was accepted by the graphics queue. */
    OWE_RC_RENDER_SUBMISSIONS,
    /* A frame failed anywhere between acquire and present. */
    OWE_RC_RENDER_FAILURES,
    /* A present was requested for a swapchain image. */
    OWE_RC_PRESENT_REQUESTS,
    /*
     * The submitted frame's fence signalled. This is GPU completion, not
     * display presentation: this backend has no presentation-feedback source,
     * so actually-displayed frames are reported as unavailable rather than
     * approximated by the present request count.
     */
    OWE_RC_GPU_COMPLETIONS,
    /* Scene simulation time was advanced by a completed frame. */
    OWE_RC_SIMULATION_TICKS,

    /* --- surface state, stored rather than accumulated --- */
    /* Bitmask of owe_renderer_pause_reason. */
    OWE_RC_PAUSE_REASONS,
    /* Interval the frame clock will use for its next tick. */
    OWE_RC_TICK_INTERVAL_MICROS,
    /* Content period the scene reported, 0 when it cannot say. */
    OWE_RC_CONTENT_PERIOD_MICROS,

    /* --- consumer work: this surface's use of decoded frames --- */
    /* Updates that promoted a newly decoded frame. */
    OWE_RC_VIDEO_FRAMES_SELECTED,
    /* Updates that re-used the frame already on screen. */
    OWE_RC_VIDEO_FRAMES_REUSED,
    /* Decoded frames that were superseded before ever being displayed. */
    OWE_RC_VIDEO_FRAMES_SKIPPED,
    /* Generation of the most recently selected frame. */
    OWE_RC_VIDEO_SELECTED_GENERATION,
    /*
     * Colour conversions and GPU imports. These belong to the texture cache
     * that performs them, which is per surface, so they are consumer work even
     * though they are about video.
     */
    OWE_RC_VIDEO_CONVERSIONS,
    OWE_RC_VIDEO_IMPORTS,

    /* --- source work, shareable between consumers --- */
    /*
     * Live decoder instances this surface consumes, and the process-unique id
     * of the single one when there is exactly one. Zero means the surface
     * consumes none, or more than one, so no single identity applies and its
     * source work cannot be de-duplicated against another surface's.
     */
    OWE_RC_VIDEO_SOURCE_COUNT,
    OWE_RC_VIDEO_SOURCE_INSTANCE,
    /* Frames the decoder produced and queued. */
    OWE_RC_VIDEO_DECODE_OUTPUTS,
    /* Seeks or resyncs the decoder was asked to perform. */
    OWE_RC_VIDEO_SEEKS,

    OWE_RC_COUNT
} owe_renderer_counter;

/*
 * Why a surface is not presenting. Reasons are independent bits: clearing one
 * never clears another.
 */
typedef enum owe_renderer_pause_reason {
    OWE_RC_PAUSE_NONE = 0,
    /* The frame clock was stopped by a pause decision (user, host or display). */
    OWE_RC_PAUSE_CLOCK_STOPPED = 1 << 0,
    /* The render surface was released or never initialized. */
    OWE_RC_PAUSE_RENDER_BLOCKED = 1 << 1,
    /* No scene is loaded. */
    OWE_RC_PAUSE_NO_SCENE = 1 << 2
} owe_renderer_pause_reason;

/* Process-wide counters that no single surface owns. */
typedef enum owe_renderer_shared_counter {
    /* Spectrum generations the analysis worker produced. */
    OWE_RC_SHARED_AUDIO_ANALYSIS_DELIVERIES = 0,
    /* Audio frames accepted for analysis. */
    OWE_RC_SHARED_AUDIO_ACCEPTED_FRAMES,
    OWE_RC_SHARED_COUNT
} owe_renderer_shared_counter;

#ifdef __cplusplus
}
#endif

#endif /* OWE_CORE_RENDERER_COUNTERS_H */
