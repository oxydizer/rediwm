// SDR captures of outputs that blend in linear light;
// see capture_sdr.h. Both hooks reach into wlroots 0.20 objects: an output
// source's public `impl`, and a screencopy frame's private commit listener.
// Re-check both after a wlroots update.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "capture_sdr.h"
#include <drm_fourcc.h>
#include "scene_output.h"
#include "scene_outputs.h"
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <wlr/interfaces/wlr_ext_image_capture_source_v1.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_ext_image_capture_source_v1.h>
#include <wlr/types/wlr_ext_image_copy_capture_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/util/log.h>

struct wrapped {
    struct wl_list link; // rediwm_capture_sdr.wrapped
    struct wlr_ext_image_capture_source_v1 *source;
    struct wlr_output *output;
    const struct wlr_ext_image_capture_source_v1_interface *original;
    struct wl_listener destroy;
};
struct rediwm_capture_sdr {
    struct rediwm_output_renderer *renderer;
    struct rediwm_scene_outputs *outputs;
    struct wl_list wrapped;
};

// Captures served from an SDR encode (`rediwm-msg perf`: capture_sdr_copies).
uint64_t rediwm_capture_sdr_copies;
// The screencopy hook is a bare wl_listener: it finds the context here.
static struct rediwm_capture_sdr *instance;
// wlroots' own handler of a screencopy frame's output commit, kept from the
// first frame taken (every frame has the same one).
static wl_notify_func_t wlroots_screencopy_commit;

static bool rgb10(uint32_t format) {
    return format == DRM_FORMAT_XBGR2101010 || format == DRM_FORMAT_ABGR2101010 ||
        format == DRM_FORMAT_XRGB2101010 || format == DRM_FORMAT_ARGB2101010;
}
static struct wlr_buffer *sdr_for(struct wlr_output *output, bool deep) {
    if (!instance) return NULL;
    struct rediwm_scene_output *out = rediwm_scene_outputs_get(instance->outputs, output);
    return out ? rediwm_scene_output_sdr_for_shm(instance->renderer, out, deep) : NULL;
}
static struct wrapped *find(struct wlr_ext_image_capture_source_v1 *source) {
    if (!instance) return NULL;
    struct wrapped *w;
    wl_list_for_each(w, &instance->wrapped, link) if (w->source == source) return w;
    return NULL;
}
static void now(struct timespec *when) {
    clock_gettime(CLOCK_MONOTONIC, when);
}

// ---- ext-image-copy-capture: a wrapped wlroots output source -------------------
static void wrapped_start(struct wlr_ext_image_capture_source_v1 *source, bool with_cursors) {
    struct wrapped *w = find(source);
    if (w && w->original->start) w->original->start(source, with_cursors);
}
static void wrapped_stop(struct wlr_ext_image_capture_source_v1 *source) {
    struct wrapped *w = find(source);
    if (w && w->original->stop) w->original->stop(source);
}
static void wrapped_request_frame(struct wlr_ext_image_capture_source_v1 *source, bool schedule_frame) {
    struct wrapped *w = find(source);
    if (w && w->original->request_frame) w->original->request_frame(source, schedule_frame);
}
// Called while the output commits, so the linear image is that commit's frame.
static void wrapped_copy_frame(struct wlr_ext_image_capture_source_v1 *source,
        struct wlr_ext_image_copy_capture_frame_v1 *frame, struct wlr_ext_image_capture_source_v1_frame_event *event) {
    struct wrapped *w = find(source);
    if (!w) return;
    struct wlr_shm_attributes shm;
    const bool deep_shm = wlr_buffer_get_shm(frame->buffer, &shm) && rgb10(shm.format);
    if (deep_shm && (frame->buffer->width != (int)source->width || frame->buffer->height != (int)source->height ||
            !source->shm_formats_len || source->shm_formats[0] != shm.format)) {
        // The output may have changed mode or returned to SDR since negotiation.
        wlr_ext_image_copy_capture_frame_v1_fail(frame, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS);
        return;
    }
    struct wlr_buffer *sdr = sdr_for(w->output, deep_shm);
    if (!sdr) {
        if (w->output->image_description)
            wlr_ext_image_copy_capture_frame_v1_fail(frame, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_UNKNOWN);
        else w->original->copy_frame(source, frame, event);
        return;
    }
    if (!wlr_ext_image_copy_capture_frame_v1_copy_buffer(frame, sdr, w->output->renderer)) return;
    rediwm_capture_sdr_copies++;
    struct timespec when;
    now(&when);
    wlr_ext_image_copy_capture_frame_v1_ready(frame, w->output->transform, &when);
}
static struct wlr_ext_image_capture_source_v1_cursor *wrapped_get_pointer_cursor(
        struct wlr_ext_image_capture_source_v1 *source, struct wlr_seat *seat) {
    struct wrapped *w = find(source);
    return w && w->original->get_pointer_cursor ? w->original->get_pointer_cursor(source, seat) : NULL;
}
static const struct wlr_ext_image_capture_source_v1_interface wrapped_impl = {
    .start = wrapped_start,
    .stop = wrapped_stop,
    .request_frame = wrapped_request_frame,
    .copy_frame = wrapped_copy_frame,
    .get_pointer_cursor = wrapped_get_pointer_cursor,
};
static void wrapped_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct wrapped *w = wl_container_of(listener, w, destroy);
    wl_list_remove(&w->destroy.link);
    wl_list_remove(&w->link);
    free(w);
}
void rediwm_capture_sdr_wrap_source(struct rediwm_capture_sdr *c, struct wlr_ext_image_capture_source_v1 *source) {
    if (find(source) || source->impl == &wrapped_impl) return;
    struct wlr_output *output = wlr_output_try_from_ext_image_capture_source_v1(source);
    if (!output) return;
    struct wrapped *w = calloc(1, sizeof(*w));
    if (!w) return;
    w->source = source;
    w->output = output;
    w->original = source->impl;
    w->destroy.notify = wrapped_destroyed;
    wl_signal_add(&source->events.destroy, &w->destroy);
    wl_list_insert(&c->wrapped, &w->link);
    source->impl = &wrapped_impl;
}
struct wlr_output *rediwm_capture_sdr_source_output(struct rediwm_capture_sdr *c, struct wlr_ext_image_capture_source_v1 *source) {
    (void)c;
    struct wrapped *w = find(source);
    return w ? w->output : wlr_output_try_from_ext_image_capture_source_v1(source);
}

// ---- wlr-screencopy: a taken frame ------------------------------------------
// Substitute only the sampled buffer. wlroots owns the damage history, copy,
// protocol replies and immediate release of both the frame and output locks.
static void taken_commit(struct wl_listener *listener, void *data) {
    struct wlr_screencopy_frame_v1 *frame = wl_container_of(listener, frame, WLR_PRIVATE.output_commit);
    const struct wlr_output_event_commit *event = data;
    if (!(event->state->committed & WLR_OUTPUT_STATE_BUFFER) || !frame->buffer) {
        wlroots_screencopy_commit(listener, data);
        return;
    }
    const bool deep = frame->buffer_cap == WLR_BUFFER_CAP_DATA_PTR && rgb10(frame->shm_format);
    struct wlr_buffer *sdr = sdr_for(frame->output, deep);
    if (!sdr) {
        if (frame->output->image_description || (deep && !rgb10(frame->output->render_format))) {
            // Fail an obsolete format or unavailable SDR encode through the
            // same wlroots path that makes a frame inert after output loss.
            frame->WLR_PRIVATE.output_destroy.notify(&frame->WLR_PRIVATE.output_destroy, frame->output);
        } else wlroots_screencopy_commit(listener, data);
        return;
    }
    struct wlr_output_state state = *event->state;
    state.buffer = sdr;
    struct wlr_output_event_commit capture = *event;
    capture.state = &state;
    struct wl_resource *resource = frame->resource;
    wlroots_screencopy_commit(listener, &capture);
    // A damage-tracked request that still awaits damage has not copied a frame.
    if (!wl_resource_get_user_data(resource)) rediwm_capture_sdr_copies++;
}
void rediwm_capture_sdr_take_screencopy(struct rediwm_capture_sdr *c, struct wlr_screencopy_frame_v1 *frame,
        bool linear_wanted) {
    (void)c;
    if (!linear_wanted && !(frame->buffer_cap == WLR_BUFFER_CAP_DATA_PTR && rgb10(frame->shm_format))) return;
    struct wl_listener *listener = &frame->WLR_PRIVATE.output_commit;
    if (listener->notify == taken_commit || !frame->buffer) return;
    if (!wlroots_screencopy_commit) wlroots_screencopy_commit = listener->notify;
    else if (listener->notify != wlroots_screencopy_commit) {
        wlr_log(WLR_ERROR, "screencopy frame with an unknown commit handler; left to wlroots");
        return;
    }
    listener->notify = taken_commit;
}

struct rediwm_capture_sdr *rediwm_capture_sdr_create(struct rediwm_output_renderer *renderer, struct rediwm_scene_outputs *outputs) {
    if (instance) return NULL;
    struct rediwm_capture_sdr *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->renderer = renderer;
    c->outputs = outputs;
    wl_list_init(&c->wrapped);
    instance = c;
    return c;
}
void rediwm_capture_sdr_destroy(struct rediwm_capture_sdr *c) {
    if (!c) return;
    struct wrapped *w, *next;
    wl_list_for_each_safe(w, next, &c->wrapped, link) {
        w->source->impl = w->original;
        wl_list_remove(&w->destroy.link);
        wl_list_remove(&w->link);
        free(w);
    }
    if (instance == c) instance = NULL;
    free(c);
}
